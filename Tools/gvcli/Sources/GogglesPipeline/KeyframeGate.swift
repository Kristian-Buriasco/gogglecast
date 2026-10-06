import Foundation

/// What the gate wants emitted for one inbound NAL.
public struct GateOutput: Equatable, Sendable {
    /// NALs to emit, in order. When the gate opens this is the cached
    /// parameter sets (SPS before PPS) followed by the IDR.
    public var nals: [Data] = []
    /// True when this call opened the gate (parameter sets + IDR seen).
    public var didStart = false
}

/// Pure state machine for the SPS+IDR started-gate (stream.py's
/// `flush_frame`). Output only begins once a parameter set has been seen
/// followed by an IDR; `rearm()` returns it to that initial state so a decoder
/// that lost its reference chain (silence, dropped slices) is only fed again
/// from the next SPS+IDR. Not thread safe on its own; `SharedKeyframeGate`
/// wraps it with a lock.
public struct KeyframeGate: Sendable {
    public static let startCodeLength = 4

    public private(set) var started = false
    private var sps: Data?
    private var pps: Data?

    public init() {}

    /// NAL type (low 5 bits after the 4-byte start code), 0xFF if too short.
    public static func nalType(of nal: Data) -> UInt8 {
        nal.count > startCodeLength ? (nal[nal.startIndex + startCodeLength] & 0x1F) : 0xFF
    }

    public mutating func process(_ nal: Data) -> GateOutput {
        if started {
            return GateOutput(nals: [nal], didStart: false)
        }
        switch Self.nalType(of: nal) {
        case 7: sps = nal
        case 8: pps = nal
        case 5:
            let params = [sps, pps].compactMap { $0 }
            if !params.isEmpty {
                started = true
                return GateOutput(nals: params + [nal], didStart: true)
            }
        default: break
        }
        // Waiting for a parameter set and/or an IDR: drop.
        return GateOutput()
    }

    /// Drops the cached parameter sets and waits for the next SPS+IDR.
    public mutating func rearm() {
        started = false
        sps = nil
        pps = nil
    }
}

/// Lock-protected `KeyframeGate`, shared between the inbound consumer task
/// and the timer task (which re-arms on silence).
public final class SharedKeyframeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = KeyframeGate()

    public init() {}

    public func process(_ nal: Data) -> GateOutput {
        lock.lock(); defer { lock.unlock() }
        return gate.process(nal)
    }

    /// Returns true if the gate was open (i.e. the call changed something).
    @discardableResult
    public func rearm() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasStarted = gate.started
        gate.rearm()
        return wasStarted
    }

    public var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return gate.started
    }
}

/// Decides when a burst of reassembler drops should re-arm the gate.
/// A dropped slice corrupts the P-frame chain, but a single drop is common
/// and re-arming on each would cause constant churn (and a black gap until
/// the next IDR), so require `threshold` drops within `window` and enforce a
/// `cooldown` between re-arms. Time is injected for testing.
public struct DropBurstDetector: Sendable {
    public let threshold: Int
    public let window: TimeInterval
    public let cooldown: TimeInterval

    private var lastTotal = 0
    private var events: [(time: Date, count: Int)] = []
    private var lastRearm: Date?

    public init(threshold: Int = 3, window: TimeInterval = 1.0, cooldown: TimeInterval = 5.0) {
        self.threshold = threshold
        self.window = window
        self.cooldown = cooldown
    }

    /// Feed the reassembler's monotonically increasing drop total. Returns
    /// true when the gate should be re-armed now.
    public mutating func record(droppedTotal: Int, now: Date) -> Bool {
        let delta = droppedTotal - lastTotal
        lastTotal = droppedTotal
        if delta > 0 { events.append((now, delta)) }
        let win = window
        events = events.filter { now.timeIntervalSince($0.time) <= win }
        let inWindow = events.reduce(0) { $0 + $1.count }
        guard inWindow >= threshold else { return false }
        if let lastRearm, now.timeIntervalSince(lastRearm) < cooldown { return false }
        lastRearm = now
        events.removeAll()
        return true
    }
}
