import Foundation
import GogglesPipeline
#if canImport(Darwin)
import Darwin
#endif

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: `SIGTERM` handling, mirroring gvcli's `installSigintHandler`
// (`Tools/gvcli/Sources/GogglesPipeline/Pipeline.swift`) pattern exactly
// (`DispatchSource.makeSignalSource`, not raw C signal-handler work) but
// for `SIGTERM` rather than `SIGINT` -- a `launchd`-managed daemon gets
// `SIGTERM` on stop/unload, not `SIGINT` (task brief). Used by both
// `--stdout` mode (same shape as gvcli's own usage) and `--xpc` mode
// (releases whatever hardware the fan-out currently has claimed, if any,
// before the process exits).
// ─────────────────────────────────────────────────────────────────────────

private var sigtermSource: DispatchSourceSignal?

/// Installs the `SIGTERM` handler: releases `GogglesPipeline`'s global
/// `currentTransport`/`currentSink` (synchronously running
/// `RNDISTransport.deinit`'s interface-release/libusb-teardown) before
/// exiting, so a subsequent `GogglesHelper`/`gvcli` run can reclaim IF0/IF1
/// cleanly -- the same clean-release contract task 1.7 established for
/// `gvcli stream`'s `SIGINT` handling, now for this daemon's `SIGTERM`.
func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        FileHandle.standardError.write(Data("\n[GogglesHelper] SIGTERM -- releasing USB interfaces and exiting...\n".utf8))
        Logging.usb.info("SIGTERM received; releasing USB interfaces and exiting")
        currentSink?.close()
        currentSink = nil
        currentTransport = nil
        exit(0)
    }
    source.resume()
    sigtermSource = source
}
