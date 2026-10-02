import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Experimental, opt-in (`AckMode.cumulativeWindow`): spec-style cumulative
// receive-window acks for the goggles' type-0x02 video stream.
//
// Background (samuelsadok/dji_protocol, udp_protocol.md -- a public RE of
// this exact UDP:9003 protocol; its handshake dump is byte-identical to
// `WireProtocol.handshakeBody`):
//
//   - Type 0x04/0x06 ack bytes 0x08..0x09 / 0x0A..0x0B are the client's
//     type-2 *receive window start / end*: "up to (including) this seq all
//     packets have been received" / "up to this seq some packets have been
//     received". They are flow control, not a per-frame receipt -- the
//     goggles keeps unacked packets cached in a bounded send window and
//     only advances it from our receive-window start. Quote: "If they
//     don't get acknowledged, the drone will stop sending video packets
//     after ~460ms and data packets a bit later."
//   - Type-2 seqs step by 8; the low 3 bits mark a retransmission
//     (…001 = resent once, …010 = resent twice).
//   - The official app acks at ~90 Hz (type 4 @30 Hz + type 6 @60 Hz), not
//     only at frame completion; the reference demo acks with
//     start == end == seq of the last-received packet.
//
// The legacy `FrameBoundaryAckTracker` (stream.py port) acks only on frame
// completion / frame-number change, with start = the frame's FIRST seq.
// Hypothesis under test: when a frame needs more packets than the goggles'
// send window allows, the goggles pauses mid-frame waiting for an ack that
// never comes (we wait for that frame to complete first) -> video silence
// until a timeout / handshake resend. This tracker acks cumulatively and
// regularly, independent of frame completion, so that cannot happen.
// ─────────────────────────────────────────────────────────────────────────

/// How `runPipeline` acknowledges inbound video packets.
public enum AckMode: String, Sendable {
    /// Legacy stream.py behavior: one ack per frame boundary/completion,
    /// range = (frame's first seq, frame's last seq). Caused the
    /// ramp-to-silence-every-~10s stall (goggles' send window starves
    /// waiting for an ack we withhold until the frame completes).
    case frameRange = "frame"
    /// Spec-style cumulative ack (see `WindowAckTracker`). Hardware-verified
    /// 2026-10-02: 25s continuous run, steady 33-36fps, zero stalls/retx
    /// (vs. a stall every ~5-10s on `.frameRange`). Now the default.
    case cumulativeWindow = "window"

    /// Name of the environment variable consulted by `fromEnvironment()`.
    public static let environmentKey = "GOGGLES_ACK_MODE"

    /// `GOGGLES_ACK_MODE=frame` reverts to the legacy per-frame ack
    /// (A/B/rollback without a rebuild); anything else, or unset, uses the
    /// hardware-verified `.cumulativeWindow` default.
    public static func fromEnvironment() -> AckMode {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey]?.lowercased() else {
            return .cumulativeWindow
        }
        return AckMode(rawValue: raw) ?? .cumulativeWindow
    }
}

/// Wrap-aware "a is newer than b" for 16-bit sequence numbers.
@inline(__always)
func seqIsNewer(_ a: UInt16, than b: UInt16) -> Bool {
    Int16(bitPattern: a &- b) > 0
}

/// Tracks the highest type-2 seq received and decides when to emit a
/// cumulative ack. Pure value type, no I/O -- unit-testable.
struct WindowAckTracker {
    /// Emit an ack after this many newly-received packets even if no frame
    /// has completed. ~700 pkt/s at 8 Mbps -> ~90 acks/s at 8, matching the
    /// official app's observed combined type-4 + type-6 ack rate.
    let ackEveryPackets: Int

    private(set) var highest: UInt16?
    private var lastAcked: UInt16?
    private var packetsSinceAck = 0

    init(ackEveryPackets: Int = 8) {
        self.ackEveryPackets = max(1, ackEveryPackets)
    }

    /// Feed one inbound video packet's outer-header seq. Returns the seq
    /// to ack (as both window start and end) if an ack is due now.
    mutating func recordPacket(seq rawSeq: UInt16) -> UInt16? {
        let seq = rawSeq & 0xFFF8 // strip retransmission marker bits
        if let h = highest {
            if seqIsNewer(seq, than: h) { highest = seq }
        } else {
            highest = seq
        }
        packetsSinceAck += 1
        if packetsSinceAck >= ackEveryPackets {
            return takeAckIfAdvanced()
        }
        return nil
    }

    /// Call on frame completion (or any other "ack now" point). Returns the
    /// seq to ack if the window advanced since the last ack.
    mutating func flush() -> UInt16? {
        takeAckIfAdvanced()
    }

    private mutating func takeAckIfAdvanced() -> UInt16? {
        packetsSinceAck = 0
        guard let h = highest else { return nil }
        if let last = lastAcked, !seqIsNewer(h, than: last) { return nil }
        lastAcked = h
        return h
    }
}
