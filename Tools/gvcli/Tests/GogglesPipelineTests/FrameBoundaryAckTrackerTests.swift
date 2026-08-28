// Task 1.7 fix round: unit tests for `FrameBoundaryAckTracker`, added in
// response to a review finding -- `Pipeline.swift` originally only sent an
// ack when `FrameReassembler.process` returned a completed NAL, so a frame
// dropped by `FrameReassembler`'s stale-eviction (age/mod-256-distance)
// was never acked. `stream.py`'s main loop acks on *every* frame_num
// boundary transition, complete or not. These tests exercise the extracted
// tracker directly (no FrameReassembler/transport/actor plumbing needed)
// to demonstrate the fixed behavior.

import Testing
@testable import GogglesPipeline

@Test func boundaryAcksIncompleteFrameWhenSupersededByNextFrameNum() {
    // Frame 5 arrives with only 2 of (say) 5 expected fragments -- never
    // completes. Frame 6 then starts. Before this fix, gvcli would never
    // ack frame 5's seq range at all (only FrameReassembler completions
    // triggered an ack); stream.py always would, at this exact boundary.
    var tracker = FrameBoundaryAckTracker()

    #expect(tracker.recordPacket(frameNum: 5, seq: 100) == nil)
    #expect(tracker.recordPacket(frameNum: 5, seq: 101) == nil)

    // Frame boundary: frame_num changes 5 -> 6. Frame 5 was never
    // completed (recordCompletion was never called for it), but the
    // boundary transition alone must still yield an ack for its range.
    let boundaryAck = tracker.recordPacket(frameNum: 6, seq: 102)
    #expect(boundaryAck != nil)
    #expect(boundaryAck?.first == 100)
    #expect(boundaryAck?.last == 101)

    // No spurious double-ack for frame 5 on a later frame_num change.
    let next = tracker.recordPacket(frameNum: 7, seq: 103)
    #expect(next?.first == 102)
    #expect(next?.last == 102)
}

@Test func completionAcksImmediatelyAndResetsTrackerForFrameNumWrap() {
    var tracker = FrameBoundaryAckTracker()

    #expect(tracker.recordPacket(frameNum: 9, seq: 200) == nil)
    #expect(tracker.recordPacket(frameNum: 9, seq: 201) == nil)

    // Caller (Pipeline.swift) signals frame 9 is complete (FrameReassembler
    // returned a NAL) -- ack fires immediately, independent of any later
    // frame_num transition.
    let completionAck = tracker.recordCompletion(frameNum: 9)
    #expect(completionAck?.first == 200)
    #expect(completionAck?.last == 201)

    // A second completion call for the same, already-flushed frame_num is
    // a no-op (nothing left to ack) -- matches stream.py's
    // `frames.pop(fnum, None)` returning nothing on a repeat flush.
    #expect(tracker.recordCompletion(frameNum: 9) == nil)

    // Frame numbers wrap every 256 frames: a *later* packet reusing
    // frame_num 9 must be treated as a brand-new frame (a fresh boundary),
    // not folded into the already-flushed range.
    #expect(tracker.recordPacket(frameNum: 9, seq: 500) == nil)
    #expect(tracker.recordPacket(frameNum: 9, seq: 501) == nil)
    let wrapCompletionAck = tracker.recordCompletion(frameNum: 9)
    #expect(wrapCompletionAck?.first == 500)
    #expect(wrapCompletionAck?.last == 501)
}

@Test func noBoundaryAckOnFirstPacketOrWhenFrameNumUnchanged() {
    var tracker = FrameBoundaryAckTracker()

    // First packet ever: no previous frame to ack (stream.py's
    // `current_frame_num is not None` guard).
    #expect(tracker.recordPacket(frameNum: 1, seq: 1) == nil)

    // Same frame_num as before: still accumulating, not a boundary.
    #expect(tracker.recordPacket(frameNum: 1, seq: 2) == nil)
    #expect(tracker.recordPacket(frameNum: 1, seq: 3) == nil)
}
