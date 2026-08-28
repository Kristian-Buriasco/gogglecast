import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 1.7 fix-round: extracted from `Pipeline.swift` so the frame-boundary
// ack logic (a review finding: `Pipeline.swift` originally only acked on
// `FrameReassembler` completion, whereas `stream.py`'s main loop acks on
// *every* frame_num transition -- complete or not -- via its single-slot
// `current_frame_num` / `last_frame_first_seq` / `last_frame_last_seq`
// globals) can be unit-tested in isolation, independent of the transport/
// USB/actor plumbing the rest of `Pipeline.swift` needs.
//
// This is a direct, pure-Swift port of stream.py's tracker: no I/O, no
// FrameReassembler dependency -- it only needs to see (frameNum, seq) per
// incoming video packet, plus an explicit "this frame just completed"
// signal from the caller, to decide when an ack's seq range is ready.
// ─────────────────────────────────────────────────────────────────────────

/// Mirrors `stream.py`'s single-slot `current_frame_num` /
/// `last_frame_first_seq` / `last_frame_last_seq` tracker: acks fire on
/// every frame-boundary transition (a differing `frameNum` between
/// consecutive packets), not only on frame completion. This is what makes
/// an incomplete frame -- superseded by a later frame_num, or evicted
/// incomplete by `FrameReassembler`'s stale-eviction -- still get its
/// seq range acked, matching `stream.py`'s wire-protocol behavior exactly.
struct FrameBoundaryAckTracker {
    private var currentFrameNum: UInt8?
    private var ranges: [UInt8: (first: UInt16, last: UInt16)] = [:]

    /// Feed one incoming video packet's `frameNum`/`seq`. Returns the seq
    /// range to ack for the *previous* frame if this packet's frameNum
    /// differs from the previously tracked one (a boundary transition),
    /// or `nil` if this packet continues the same frame as before.
    ///
    /// Matches stream.py's:
    /// ```
    /// if current_frame_num is not None and frame_num != current_frame_num:
    ///     flush_frame(current_frame_num)
    ///     if last_frame_first_seq is not None:
    ///         ack(last_frame_first_seq, last_frame_last_seq)
    ///     last_frame_first_seq = None
    /// current_frame_num = frame_num
    /// ...
    /// if last_frame_first_seq is None: last_frame_first_seq = pkt_seq
    /// last_frame_last_seq = pkt_seq
    /// ```
    mutating func recordPacket(frameNum: UInt8, seq: UInt16) -> (first: UInt16, last: UInt16)? {
        var boundaryAck: (first: UInt16, last: UInt16)?
        if let currentFrameNum, currentFrameNum != frameNum {
            boundaryAck = ranges.removeValue(forKey: currentFrameNum)
        }
        currentFrameNum = frameNum

        if var range = ranges[frameNum] {
            range.last = seq
            ranges[frameNum] = range
        } else {
            ranges[frameNum] = (first: seq, last: seq)
        }

        return boundaryAck
    }

    /// Call when `FrameReassembler.process` reports `frameNum` complete.
    /// Returns the seq range to ack for that frame, and resets the
    /// tracker so a later packet with the same frameNum (frame numbers
    /// wrap every 256 frames) is treated as a fresh boundary rather than
    /// a same-frame continuation.
    ///
    /// Matches stream.py's frag-count-reached branch:
    /// ```
    /// if got >= frag_count:
    ///     flush_frame(frame_num)
    ///     ack(last_frame_first_seq, last_frame_last_seq)
    ///     last_frame_first_seq = None
    ///     current_frame_num = None
    /// ```
    mutating func recordCompletion(frameNum: UInt8) -> (first: UInt16, last: UInt16)? {
        guard let range = ranges.removeValue(forKey: frameNum) else { return nil }
        if currentFrameNum == frameNum {
            currentFrameNum = nil
        }
        return range
    }
}
