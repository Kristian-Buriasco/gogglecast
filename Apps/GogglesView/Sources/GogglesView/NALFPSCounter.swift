import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1, brief point 2: "when nalUnit(...) fires on your exported client
// object, maintain a simple per-second fps counter (same spirit as
// gvcli's --stats counter from Task 1.7/GogglesPipeline)".
//
// This is a deliberate reimplementation, not a reuse of
// `Tools/gvcli/Sources/GogglesPipeline/PipelineState.swift`'s actor. Reuse
// was considered and rejected: `PipelineState` lives in the `GogglesPipeline`
// library product, which pulls in `GogglesProtocol`/`GogglesUSB` (and
// transitively `CLibusb`) as build dependencies (see
// `Tools/gvcli/Package.swift`) -- entirely reasonable for `GogglesHelper`,
// which already needs the whole pipeline to *drive* streaming, but wrong
// for this app target, which only *observes* already-decoded NAL callbacks
// delivered over XPC and has no business linking libusb at all. The
// counting logic itself is intentionally identical in spirit (a per-second
// frame count, reset every second, logged once per second) -- see
// `PipelineState.snapshotAndResetPerSecond()` / `Pipeline.swift`'s
// `[stats] t=%4ds fps=%3d ...` reporting loop, which this mirrors in
// format for easy side-by-side comparison against `gvcli --stats`.
//
// Also deliberately independent of `GogglesClientProtocol.stats(_:)`
// (`StreamStats`, fed by the *helper's own* copy of this same counting
// logic, `HelperService.pipelineDidUpdateStats`). `HelperClient` logs both
// (see `HelperClient.handleStats`), but this counter's whole point is to
// verify NAL delivery independently, end to end, over the XPC boundary --
// counting individual `nalUnit` callbacks this process actually received --
// rather than just trusting/relaying a number the helper computed and is
// self-reporting. If the two numbers disagree, that's a real signal (NAL
// delivery isn't keeping up, or drops are asymmetric); if this class merely
// echoed `StreamStats.fps`, that check would be impossible.
// ─────────────────────────────────────────────────────────────────────────

/// A simple per-second frame counter fed by `HelperClient.handleNALUnit`.
/// Not an `actor` (unlike `PipelineState`) because there's no `async` work
/// to interleave here -- a private serial `DispatchQueue` is enough and
/// matches the idiom the rest of this codebase already uses for XPC-callback
/// -driven mutable state (`HelperService.stateQueue`).
final class NALFPSCounter {
    private let queue = DispatchQueue(label: "\(Logging.subsystem).client.fpscounter")
    private var frameCountThisSecond = 0
    private var cumulativeFrameCount = 0
    private var elapsedSeconds = 0
    private var timer: DispatchSourceTimer?

    /// Also print to stdout, not just `os_log`, so a `--test-client` run in
    /// an interactive terminal shows fps output directly, the same way
    /// `gvcli --stats` does (rather than requiring a separate `log stream`
    /// session to see anything live).
    private let alsoPrint: Bool

    init(alsoPrint: Bool = true) {
        self.alsoPrint = alsoPrint
    }

    /// Starts the 1Hz reporting timer. Idempotent -- calling this again
    /// while already running is a no-op (matters because `HelperClient`
    /// reconnection could otherwise call this more than once).
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            frameCountThisSecond = 0
            cumulativeFrameCount = 0
            elapsedSeconds = 0
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in
                self?.reportAndReset()
            }
            t.resume()
            timer = t
        }
    }

    /// Stops the timer and resets counters (used on disconnect/teardown so
    /// a later reconnect's counter starts clean rather than continuing an
    /// old cumulative total across a connection that no longer exists).
    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            frameCountThisSecond = 0
            cumulativeFrameCount = 0
            elapsedSeconds = 0
        }
    }

    /// Called once per received `nalUnit` callback.
    func recordFrame() {
        queue.async { [self] in
            frameCountThisSecond += 1
            cumulativeFrameCount += 1
        }
    }

    /// Must only run on `queue` (called from the timer's own event handler).
    private func reportAndReset() {
        elapsedSeconds += 1
        let fps = frameCountThisSecond
        frameCountThisSecond = 0
        let cumulative = cumulativeFrameCount
        let line = String(
            format: "[client-fps] t=%4ds fps=%3d cum_frames=%d (client-side NAL-callback count, HelperClient)",
            elapsedSeconds, fps, cumulative
        )
        Logging.stats.info("\(line, privacy: .public)")
        if alsoPrint {
            print(line)
        }
    }
}
