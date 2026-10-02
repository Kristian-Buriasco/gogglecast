import Foundation
import GogglesPipeline
import GogglesUSB

/// `gvcli stream --out <path> [--stats]`: brings up the real pipeline
/// (`RNDISTransport` -> outer-header/DUML parsing -> `FrameReassembler`)
/// against live hardware and writes Annex-B output to `<path>` (a regular
/// file or a FIFO). Requires root on macOS to claim IF0/IF1 (same
/// constraint `RNDISTransport` itself documents).
func runStreamCommand(args: [String]) async throws {
    var outPath: String?
    var stats = false
    var ackMode = AckMode.fromEnvironment()

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out":
            i += 1
            guard i < args.count else { throw GVCLIError.message("--out requires a path argument") }
            outPath = args[i]
        case "--stats":
            stats = true
        case "--ack-mode":
            i += 1
            guard i < args.count, let mode = AckMode(rawValue: args[i]) else {
                throw GVCLIError.message("--ack-mode requires 'frame' (default, stream.py-compatible) or 'window' (experimental cumulative acks)")
            }
            ackMode = mode
        default:
            throw GVCLIError.message("Unknown argument '\(args[i])' for 'stream'. Usage: gvcli stream --out <path> [--stats] [--ack-mode frame|window]")
        }
        i += 1
    }
    guard let outPath else {
        throw GVCLIError.message("'stream' requires --out <path>. Usage: gvcli stream --out <path> [--stats] [--ack-mode frame|window]")
    }

    FileHandle.standardError.write(Data("[gvcli] Connecting to goggles over USB (RNDIS)...\n".utf8))
    let transport = try RNDISTransport()
    printDeviceInfoBanner(transport.deviceInfo)
    installSigintHandler()
    try await runPipeline(transport: transport, outPath: outPath, stats: stats, ackMode: ackMode)
}
