import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 1.4: transport abstraction + mock (plan task 1.4 brief).
//
// `GogglesTransport` is the seam between "however bytes get to/from the
// goggles" (RNDIS/USB today, a future WiFiUDPTransport later -- both in
// OTHER packages, not this one) and the protocol core built in tasks
// 1.1-1.3 (framing primitives, outer-header/DUML codec, fragment
// reassembler). Per the design doc's stated rationale, everything above the
// transport should be bit-for-bit identical regardless of which concrete
// transport is underneath -- so the abstraction boundary is drawn at
// "UDP:9003 payload bytes in, raw bytes out to write", not at "raw Ethernet
// frames" or "USB bulk transfers". A conforming transport (real or mock) is
// responsible for whatever Ethernet/ARP/RNDIS/Wi-Fi-socket handling its own
// medium needs to get to that point.
// ─────────────────────────────────────────────────────────────────────────

/// Abstract bidirectional byte transport to the goggles, per plan task 1.4.
///
/// `inbound` yields UDP:9003 *payload* bytes (i.e. what design §3.3 calls
/// the outer header onward -- exactly what `WireProtocol.parseOuter` and
/// `FrameReassembler` expect), not raw Ethernet frames. A conforming
/// transport does its own Ethernet/ARP/UDP (or RNDIS, or a real Wi-Fi UDP
/// socket) handling internally so the protocol core never needs to know
/// which medium it's running over.
///
/// `send` mirrors that same abstraction level: callers pass the same
/// UDP-payload bytes `WireProtocol.buildOuter`/`buildHandshake`/`buildAck`
/// etc. produce, and the transport wraps them however its medium requires
/// before actually writing them out.
public protocol GogglesTransport {
    /// Sends one outbound UDP-payload frame (an 8-byte outer header +
    /// body, as built by `WireProtocol`). Throws on a transport-level
    /// failure (e.g. a real USB/RNDIS write error); a mock or offline
    /// transport may simply record the call and never throw.
    func send(_ frame: Data) throws

    /// Inbound UDP:9003 payload bytes, one element per received packet, in
    /// the order they were (or, for a mock, are simulated to have been)
    /// received. Finishes when the transport is done (e.g. a capture
    /// replay reaching EOF); a live transport's stream would not normally
    /// finish during a session.
    var inbound: AsyncStream<Data> { get }
}

// MARK: - MockTransport

/// A `GogglesTransport` that replays a `.gvcap` capture file (format:
/// `Fixtures/README.md`) instead of talking to real hardware -- the
/// offline/no-hardware testing story from design §9.1 and plan task 0.3.
///
/// Parsing: `.gvcap` records store raw Ethernet frames (dest MAC, src MAC,
/// ethertype, payload -- exactly as they crossed the RNDIS link). Per this
/// task's abstraction-boundary decision above, `MockTransport` does its own
/// minimal Ethernet/IPv4/UDP parsing (`RawNet.parseUDP`, already built in
/// task 1.1) to filter each record down to just its UDP payload, so
/// `inbound` never leaks Ethernet-layer bytes to a consumer. Only INBOUND
/// records (direction `0x00`) whose UDP source port is 9003 (the goggles'
/// outbound port, per `stream.py`'s `sport != DST_PORT` check) are
/// forwarded; everything else (outbound records, ARP frames, any other
/// traffic) is silently skipped -- matching what a real transport's
/// consumer would see arrive on `inbound`.
///
/// Timing: see `Pacing` below.
public final class MockTransport: GogglesTransport {

    // MARK: - Pacing

    /// Controls how `inbound` paces replayed frames relative to each
    /// other. The `.gvcap` format's host timestamps (design: `Fixtures/
    /// README.md`) let a replay reproduce the original inter-frame timing
    /// exactly -- but doing that at full fidelity in an automated test
    /// would make the test as slow as the original capture (`clean-
    /// start.gvcap` spans several real seconds) and introduce scheduler-
    /// jitter flakiness risk. `Pacing` makes the tradeoff explicit and
    /// selectable per use site rather than baking in one answer:
    ///
    /// - `.realTime`: delay between successive `inbound` yields matches
    ///   the recorded inter-arrival time exactly. Intended for a future
    ///   manual/demo replay (e.g. driving a UI against a capture at
    ///   believable speed), not for automated tests.
    /// - `.accelerated(multiplier:maxDelay:)`: recorded delays are divided
    ///   by `multiplier` and then capped at `maxDelay`, so relative
    ///   ordering and *rough* relative spacing survive (useful if a test
    ///   ever wants to exercise the reassembler's time-based eviction,
    ///   design §5.2's 250ms rule, without waiting out the real capture)
    ///   while keeping a hard ceiling on how long any single gap can be.
    /// - `.immediate`: no delay at all -- every frame is yielded back-to-
    ///   back as fast as the consumer can read them, preserving only
    ///   ordering, not timing. This is what this task's integration test
    ///   uses: the exit criterion is about the *sequence* of NALs the
    ///   reassembler emits, not wall-clock timing, and a multi-second (or
    ///   longer) test run is a real recurring cost.
    public enum Pacing {
        case realTime
        case accelerated(multiplier: Double, maxDelay: TimeInterval = 0.05)
        case immediate
    }

    // MARK: - GogglesTransport

    public let inbound: AsyncStream<Data>

    /// `send` has nothing to verify against for this task (the exit
    /// criterion is entirely about the inbound NAL sequence), so this is a
    /// recording-only stub: every call is appended here for a test/caller
    /// to inspect if it ever wants to, and nothing is ever thrown.
    public func send(_ frame: Data) throws {
        sentFrames.append(frame)
    }

    /// Every frame passed to `send`, in call order. Inspectable by tests;
    /// not otherwise used by `MockTransport` itself.
    public private(set) var sentFrames: [Data] = []

    // MARK: - Init

    /// Loads and parses `capturePath` (a `.gvcap` file) up front, then
    /// starts an internal replay task that paces (`pacing`) and yields the
    /// filtered inbound UDP-payload frames on `inbound`.
    ///
    /// Throws if the file can't be read or doesn't start with the expected
    /// `"GVCAP001"` magic.
    public init(capturePath: URL, pacing: Pacing = .realTime) throws {
        let records = try Self.loadInboundRecords(capturePath: capturePath)
        var continuation: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream<Data> { continuation = $0 }
        self.continuationBox = continuation
        self.records = records
        self.pacing = pacing
        // Last statement: captures `self` weakly, so every other stored
        // property must already be set (Swift requires full initialization
        // before `self` can be referenced inside a closure, even a
        // `[weak self]` one).
        self.replayTask = Task { [weak self] in await self?.replay() }
    }

    deinit {
        replayTask?.cancel()
    }

    // MARK: - Private state

    private let records: [(timestamp: Double, payload: Data)]
    private let pacing: Pacing
    private let continuationBox: AsyncStream<Data>.Continuation
    private var replayTask: Task<Void, Never>?

    // MARK: - Replay

    private func replay() async {
        var previousTimestamp: Double?
        for record in records {
            if Task.isCancelled { break }
            if let previousTimestamp {
                let rawDelay = max(0, record.timestamp - previousTimestamp)
                let delay = Self.scaledDelay(rawDelay, pacing: pacing)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
                }
            }
            previousTimestamp = record.timestamp
            continuationBox.yield(record.payload)
        }
        continuationBox.finish()
    }

    static func scaledDelay(_ rawDelay: Double, pacing: Pacing) -> Double {
        switch pacing {
        case .realTime:
            return rawDelay
        case .immediate:
            return 0
        case .accelerated(let multiplier, let maxDelay):
            guard multiplier > 0 else { return 0 }
            return min(rawDelay / multiplier, maxDelay)
        }
    }

    // MARK: - .gvcap parsing

    private static let magic: [UInt8] = Array("GVCAP001".utf8)
    private static let directionInbound: UInt8 = 0x00
    private static let goggleUDPPort: UInt16 = 9003

    enum GVCAPError: Error, CustomStringConvertible {
        case fileTooShort
        case badMagic
        case truncatedRecord

        var description: String {
            switch self {
            case .fileTooShort: return ".gvcap file shorter than the 8-byte magic header"
            case .badMagic: return ".gvcap file does not start with the \"GVCAP001\" magic"
            case .truncatedRecord: return ".gvcap file ends mid-record (truncated capture)"
            }
        }
    }

    /// Parses every record in a `.gvcap` file and returns just the ones
    /// this transport cares about: inbound (direction `0x00`) records
    /// whose Ethernet frame is a UDP packet sourced from port 9003 (the
    /// goggles' outbound port -- matches `stream.py`'s `sport != DST_PORT`
    /// filter), reduced to their UDP payload bytes plus the record's
    /// original host timestamp (for pacing).
    static func loadInboundRecords(capturePath: URL) throws -> [(timestamp: Double, payload: Data)] {
        let data = try Data(contentsOf: capturePath)
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count else { throw GVCAPError.fileTooShort }
        guard Array(bytes[0..<magic.count]) == magic else { throw GVCAPError.badMagic }

        var out: [(timestamp: Double, payload: Data)] = []
        var i = magic.count
        let n = bytes.count
        while i < n {
            guard i + 13 <= n else { throw GVCAPError.truncatedRecord }
            let tsBits = (0..<8).reduce(UInt64(0)) { acc, j in acc | (UInt64(bytes[i + j]) << (8 * j)) }
            let timestamp = Double(bitPattern: tsBits)
            let direction = bytes[i + 8]
            let frameLen = (0..<4).reduce(UInt32(0)) { acc, j in acc | (UInt32(bytes[i + 9 + j]) << (8 * j)) }
            let frameStart = i + 13
            let frameEnd = frameStart + Int(frameLen)
            guard frameEnd <= n else { throw GVCAPError.truncatedRecord }

            if direction == directionInbound {
                let frame = Data(bytes[frameStart..<frameEnd])
                if let parsed = RawNet.parseUDP(frame), parsed.srcPort == goggleUDPPort {
                    out.append((timestamp: timestamp, payload: parsed.payload))
                }
            }
            i = frameEnd
        }
        return out
    }
}
