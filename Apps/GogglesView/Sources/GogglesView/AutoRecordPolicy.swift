import Foundation

/// Automatic recording for one feed, driven by its frame rate: start once the rate holds above `startFps` and the
/// picture is really changing, stop when the rate sits at 0, and start again when the feed comes back. Pure: the
/// caller supplies the readings and the clock. It only stops recordings it started itself, and after a manual
/// stop it waits for the feed to go away and return before it starts again.
struct AutoRecordPolicy {
    enum Action: Equatable { case none, start, stop }

    static let startFps = 10
    static let startHold: TimeInterval = 1
    static let stopHold: TimeInterval = 2
    /// A recorder takes a moment to report that it runs; a stop seen sooner than this is not a manual stop.
    static let startGrace: TimeInterval = 3

    private var gate = PictureChangeGate()
    private var aboveSince: Date?
    private var zeroSince: Date?
    private var startedAt: Date?
    private var suppressed = false

    var isSuppressed: Bool { suppressed }

    /// `sample` is only needed while a start is possible (not recording, fps above the threshold).
    mutating func observe(fps: Int?, sample: PictureWatch.Sample?, recording: Bool, enabled: Bool, now: Date) -> Action {
        guard enabled else { self = AutoRecordPolicy(); return .none }
        let f = fps ?? 0
        zeroSince = f == 0 ? (zeroSince ?? now) : nil
        aboveSince = f > Self.startFps ? (aboveSince ?? now) : nil
        let zeroHeld = zeroSince.map { now.timeIntervalSince($0) >= Self.stopHold } ?? false

        if recording {
            if startedAt != nil, zeroHeld { startedAt = nil; return .stop }
            return .none
        }
        if let s = startedAt {
            if now.timeIntervalSince(s) < Self.startGrace { return .none }
            startedAt = nil          // it ended without our stop: someone stopped it by hand (or it failed)
            suppressed = true
        }
        if suppressed {
            if zeroHeld { suppressed = false }
            return .none
        }
        let changing = f > Self.startFps ? gate.observe(sample) : { gate.reset(); return false }()
        if changing, let a = aboveSince, now.timeIntervalSince(a) >= Self.startHold {
            startedAt = now
            return .start
        }
        return .none
    }
}
