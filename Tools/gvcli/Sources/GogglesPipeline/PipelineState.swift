import Foundation

/// Shared mutable state for `runPipeline`'s two concurrent tasks (the
/// inbound-packet consumer and the periodic handshake-resend/I-frame-retry/
/// stats-reporting timer) -- an `actor` so both tasks can touch it
/// (sequence-number allocation, timer bookkeeping, per-second counters)
/// without a hand-rolled lock.
actor PipelineState {
    // MARK: - Sequence counter

    private var seq: UInt16 = 0

    /// Allocates the next outer-header `seq` value, matching `stream.py`'s
    /// single shared `seq_counter` (every send site -- handshake, ack,
    /// I-frame request -- draws from the same counter).
    func nextSeq() -> UInt16 {
        defer { seq &+= 1 }
        return seq
    }

    // MARK: - Timers (2s handshake-resend / 1.5s I-frame-retry, matching stream.py)

    private(set) var lastRxTime = Date()
    private(set) var started = false
    private(set) var lastIframeRequestTime = Date()

    func markRx() { lastRxTime = Date() }
    func markStarted() { started = true }
    /// Gate re-armed (silence / dropped-frame burst): I-frame requests resume.
    func markStopped() { started = false; lastIframeRequestTime = Date.distantPast }
    func markIframeRequested() { lastIframeRequestTime = Date() }

    func snapshotTimers() -> (lastRx: Date, started: Bool, lastIframe: Date) {
        (lastRxTime, started, lastIframeRequestTime)
    }

    // MARK: - Stats counters (design §9.2 parity metrics)

    private var lastKnownDroppedTotal = 0
    private var frameCountThisSecond = 0
    private var byteCountThisSecond = 0
    private var dropCountThisSecond = 0
    private var cumulativeFrameCount = 0
    private var cumulativeByteCount = 0
    private var cumulativeDropCount = 0

    /// Records one emitted (post started-gate) NAL's worth of output.
    func recordEmittedFrame(bytes: Int) {
        frameCountThisSecond += 1
        byteCountThisSecond += bytes
        cumulativeFrameCount += 1
        cumulativeByteCount += bytes
    }

    /// Folds `FrameReassembler.droppedFrameCount`'s latest running total
    /// into the per-second/cumulative drop counters. Called with the
    /// reassembler's monotonically-increasing counter after every
    /// `process(videoPayload:receivedAt:)` call so a caller never has to
    /// compute the delta itself.
    func updateDroppedTotal(_ total: Int) {
        let delta = total - lastKnownDroppedTotal
        if delta > 0 {
            dropCountThisSecond += delta
            cumulativeDropCount += delta
        }
        lastKnownDroppedTotal = total
    }

    func snapshotAndResetPerSecond() -> (fps: Int, bytes: Int, drops: Int) {
        let result = (frameCountThisSecond, byteCountThisSecond, dropCountThisSecond)
        frameCountThisSecond = 0
        byteCountThisSecond = 0
        dropCountThisSecond = 0
        return result
    }

    func cumulativeSnapshot() -> (frames: Int, bytes: Int, drops: Int) {
        (cumulativeFrameCount, cumulativeByteCount, cumulativeDropCount)
    }

    // MARK: - Protocol diagnostics (`[proto]` stderr line under --stats)
    //
    // Per udp_protocol.md (samuelsadok/dji_protocol), every goggles->host
    // type-0x01 (telemetry, ~10 Hz) and type-0x02 (video) packet carries the
    // goggles' *type-2 send window* in body bytes 0..7: window start, window
    // end, resend state 1, resend state 2 (u16 LE each). Logging these per
    // second shows directly whether a video silence is the goggles blocking
    // on its flow-control window (end - start pinned at a cap, start not
    // advancing, resend states non-zero) while telemetry keeps flowing.

    struct GogglesWindow: Sendable {
        var start: UInt16
        var end: UInt16
        var resend1: UInt16
        var resend2: UInt16
    }

    private var inboundTypeCountsThisSecond: [UInt8: Int] = [:]
    private var retransmittedVideoThisSecond = 0
    private var latestGogglesWindow: GogglesWindow?
    private var videoPacketsThisSecond = 0

    func noteInbound(pktType: UInt8, seq: UInt16, body: Data) {
        inboundTypeCountsThisSecond[pktType, default: 0] += 1
        if pktType == 0x02 {
            videoPacketsThisSecond += 1
            if seq & 0x7 != 0 { retransmittedVideoThisSecond += 1 }
        }
        if (pktType == 0x01 || pktType == 0x02), body.count >= 8 {
            let b = body.startIndex
            func u16(_ o: Int) -> UInt16 { UInt16(body[b + o]) | (UInt16(body[b + o + 1]) << 8) }
            latestGogglesWindow = GogglesWindow(start: u16(0), end: u16(2), resend1: u16(4), resend2: u16(6))
        }
    }

    /// Returns a one-line summary and resets the per-second counters.
    func snapshotAndResetProto(lastAck: UInt16?) -> String {
        let types = inboundTypeCountsThisSecond.keys.sorted()
            .map { String(format: "t%02X=%d", $0, inboundTypeCountsThisSecond[$0] ?? 0) }
            .joined(separator: " ")
        var line = "in{\(types.isEmpty ? "none" : types)} retx=\(retransmittedVideoThisSecond)"
        if let w = latestGogglesWindow {
            let outstanding = Int(w.end &- w.start) / 8
            line += String(format: " gwin=%04X..%04X (%d pkts) rs1=%04X rs2=%04X", w.start, w.end, outstanding, w.resend1, w.resend2)
        }
        if let lastAck {
            line += String(format: " lastAck=%04X", lastAck)
        }
        inboundTypeCountsThisSecond.removeAll(keepingCapacity: true)
        retransmittedVideoThisSecond = 0
        videoPacketsThisSecond = 0
        return line
    }

    // MARK: - Cumulative-window ack keepalive (AckMode.cumulativeWindow)

    private(set) var lastWindowAck: UInt16?
    private(set) var lastVideoRxTime = Date.distantPast
    private(set) var lastAckSentTime = Date.distantPast

    func recordWindowAck(_ seq: UInt16) {
        lastWindowAck = seq
        lastAckSentTime = Date()
    }

    func markVideoRx() { lastVideoRxTime = Date() }

    func windowAckSnapshot() -> (lastAck: UInt16?, lastVideoRx: Date, lastAckSent: Date) {
        (lastWindowAck, lastVideoRxTime, lastAckSentTime)
    }
}
