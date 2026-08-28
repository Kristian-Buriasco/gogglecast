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
}
