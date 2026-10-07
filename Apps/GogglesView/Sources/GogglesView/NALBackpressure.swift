import Foundation

/// Bounds how many NAL bytes are queued for the main queue. If the main queue stalls, the helper
/// keeps delivering (about 2.5 MB/s), so without a limit the backlog grows without bound.
///
/// Above `limit` pending bytes it drops NALs until the next parameter set or IDR arrives while the
/// backlog has drained below `resumeBelow`, so the decoder restarts cleanly instead of reading a
/// stream with holes. Pure value type; the caller owns locking.
struct NALBackpressure {
    enum Verdict: Equatable {
        case deliver
        /// Deliver, and this NAL ends a drop run (it is a keyframe start).
        case resume
        /// Drop. `firstOfRun` is true for the first dropped NAL of a run (log and notify once).
        case drop(firstOfRun: Bool)
    }

    let limit: Int
    let resumeBelow: Int
    private(set) var pendingBytes = 0
    private(set) var dropping = false
    private(set) var droppedCount = 0

    init(limit: Int = 8 * 1024 * 1024, resumeBelow: Int? = nil) {
        self.limit = limit
        self.resumeBelow = resumeBelow ?? limit / 2
    }

    /// `startsKeyframe`: a parameter set or an IDR slice.
    mutating func admit(bytes: Int, startsKeyframe: Bool) -> Verdict {
        if dropping {
            if startsKeyframe, pendingBytes <= resumeBelow {
                dropping = false
                pendingBytes += bytes
                return .resume
            }
            droppedCount += 1
            return .drop(firstOfRun: false)
        }
        if pendingBytes + bytes > limit {
            dropping = true
            droppedCount += 1
            return .drop(firstOfRun: true)
        }
        pendingBytes += bytes
        return .deliver
    }

    /// The main queue handled a delivered NAL.
    mutating func delivered(bytes: Int) {
        pendingBytes = max(0, pendingBytes - bytes)
    }
}
