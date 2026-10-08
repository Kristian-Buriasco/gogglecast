import Foundation
import GogglesProtocol

/// What the session wants done after an event.
public struct SessionActions: Equatable {
    /// UDP payloads to send to the goggles.
    public var replies: [Data] = []
    /// Annex-B H.264 NAL units to output, in order (each starts with 00 00 00 01).
    public var nals: [Data] = []
    public init() {}
}

/// Pure client logic for the goggles' UDP 9003 protocol: handshake, silence resend,
/// cumulative window acks, fragment reassembly, and a keyframe gate so output only starts
/// at SPS+PPS+IDR. No I/O and no clock of its own, so it is fully testable.
///
/// Mirrors `gvcli`'s pipeline (window-ack mode); see docs/design.md section 3.3.
public struct StreamSession {
    public let sessionId: UInt16
    public private(set) var seq: UInt16
    public private(set) var started = false
    public private(set) var videoPackets = 0
    public private(set) var framesOut = 0
    public private(set) var droppedFrames = 0

    private let reassembler = FrameReassembler()
    private var lastRx: Date
    private var lastAckSent: Date
    private var highest: UInt16?
    private var lastAcked: UInt16?
    private var sinceAck = 0
    private var sps: Data?
    private var pps: Data?

    /// Silence after which the handshake is sent again.
    public static let silenceTimeout: TimeInterval = 2.0
    private static let ackEveryPackets = 8

    public init(sessionId: UInt16 = WireProtocol.randomSessionId(), now: Date = Date()) {
        self.sessionId = sessionId
        self.seq = 0
        self.lastRx = now
        self.lastAckSent = now
    }

    private mutating func nextSeq() -> UInt16 { defer { seq &+= 1 }; return seq }

    /// First packet to send.
    public mutating func start(now: Date = Date()) -> [Data] {
        lastRx = now
        return [WireProtocol.buildHandshake(seq: nextSeq(), sessionId: sessionId)]
    }

    /// Call a few times a second. Resends the handshake after 2 s without any packet, and
    /// re-arms the keyframe gate (the picture chain cannot be trusted after a gap).
    public mutating func tick(now: Date) -> [Data] {
        var out: [Data] = []
        if now.timeIntervalSince(lastRx) > Self.silenceTimeout {
            out.append(WireProtocol.buildHandshake(seq: nextSeq(), sessionId: sessionId))
            lastRx = now
            rearm()
        }
        // A lost ack must never leave the goggles' send window blocked.
        if let h = highest, h != lastAcked, now.timeIntervalSince(lastAckSent) > 0.2 {
            out.append(ack(h, now: now))
        }
        return out
    }

    private mutating func rearm() {
        started = false
        sps = nil
        pps = nil
    }

    private mutating func ack(_ value: UInt16, now: Date) -> Data {
        lastAcked = value
        lastAckSent = now
        sinceAck = 0
        return WireProtocol.buildAck(startSeq: value, endSeq: value, seq: nextSeq(), sessionId: sessionId)
    }

    private static func newer(_ a: UInt16, than b: UInt16) -> Bool { Int16(bitPattern: a &- b) > 0 }

    /// Feed one received UDP payload (from the goggles' port 9003).
    public mutating func receive(_ packet: Data, now: Date) -> SessionActions {
        var actions = SessionActions()
        guard let outer = WireProtocol.parseOuter(packet) else { return actions }
        lastRx = now
        guard outer.pktType == WireProtocol.packetTypeVideo, outer.body.count >= 12 else { return actions }
        videoPackets += 1

        let s = outer.seq & 0xFFF8 // low bits mark a retransmission
        if let h = highest { if Self.newer(s, than: h) { highest = s } } else { highest = s }
        sinceAck += 1
        var ackNow = sinceAck >= Self.ackEveryPackets

        let before = reassembler.droppedFrameCount
        if let nal = reassembler.process(videoPayload: outer.body, receivedAt: now) {
            ackNow = true
            actions.nals = gate(nal)
            framesOut += actions.nals.isEmpty ? 0 : 1
        }
        droppedFrames += reassembler.droppedFrameCount - before
        if ackNow, let h = highest, h != lastAcked { actions.replies.append(ack(h, now: now)) }
        return actions
    }

    private mutating func gate(_ nal: Data) -> [Data] {
        if started { return [nal] }
        let type = nal.count > 4 ? nal[nal.startIndex + 4] & 0x1F : 0xFF
        switch type {
        case 7: sps = nal
        case 8: pps = nal
        case 5:
            let params = [sps, pps].compactMap { $0 }
            if !params.isEmpty { started = true; return params + [nal] }
        default: break
        }
        return []
    }
}
