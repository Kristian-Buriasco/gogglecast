import Foundation
import GogglesPipeline
import GogglesUSB

/// `GogglesHelper --stdout`: the Phase-1-equivalent mode (design §8.4's
/// staging rationale, copied verbatim into the task brief) -- connects to
/// the goggles over USB/RNDIS, runs the exact same `GogglesPipeline`
/// driving loop `gvcli stream` uses, and writes raw Annex-B H.264 straight
/// to this process's stdout (`OutputSink.standardOutput()`) instead of
/// `--out <path>`. No `NSXPCListener`, no subscriber registry, no
/// `os_log`-only logging (stderr banners too, matching `gvcli`) -- this
/// mode exists specifically so protocol regressions can be diagnosed
/// without the XPC layer in the way.
func runStdoutMode() async throws {
    FileHandle.standardError.write(Data("[GogglesHelper] Connecting to goggles over USB (RNDIS)...\n".utf8))
    Logging.usb.info("connecting to goggles over USB (RNDIS), --stdout mode")

    let transport = try RNDISTransport()
    let info = transport.deviceInfo
    FileHandle.standardError.write(Data(
        "[GogglesHelper] Connected: \(info.product ?? "?") S/N \(info.serial ?? "?"), bus \(info.bus) addr \(info.address)\n".utf8
    ))
    Logging.usb.info("claimed IF0/IF1, device: \(info.product ?? "?", privacy: .public)")

    installSigtermHandler()

    let sink = OutputSink.standardOutput()
    try await runPipeline(transport: transport, sink: sink, stats: false)
}
