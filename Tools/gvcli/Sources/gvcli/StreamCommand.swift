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
    var dumpTelemetryPath: String?

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
        case "--dump-telemetry":
            i += 1
            guard i < args.count else { throw GVCLIError.message("--dump-telemetry requires a path argument") }
            dumpTelemetryPath = args[i]
        default:
            throw GVCLIError.message("Unknown argument '\(args[i])' for 'stream'. Usage: gvcli stream --out <path> [--stats] [--ack-mode frame|window] [--dump-telemetry <path>]")
        }
        i += 1
    }
    guard let outPath else {
        throw GVCLIError.message("'stream' requires --out <path>. Usage: gvcli stream --out <path> [--stats] [--ack-mode frame|window] [--dump-telemetry <path>]")
    }

    FileHandle.standardError.write(Data("[gvcli] Connecting to goggles over USB (RNDIS)...\n".utf8))
    let transport = try RNDISTransport()
    printDeviceInfoBanner(transport.deviceInfo)
    installSigintHandler()
    let telemetryDump = try openTelemetryDump(dumpTelemetryPath)
    defer { telemetryDump?.close() }
    try await runPipeline(transport: transport, outPath: outPath, stats: stats, ackMode: ackMode, telemetryDump: telemetryDump)
}

/// Opens the `--dump-telemetry` JSONL file (append mode), or returns nil
/// when the flag wasn't given. Shared by `stream` and `replay`.
func openTelemetryDump(_ path: String?) throws -> TelemetryDumpWriter? {
    guard let path else { return nil }
    let writer = try TelemetryDumpWriter(path: path)
    FileHandle.standardError.write(Data("[gvcli] Appending inbound telemetry (non-video packets) as JSON lines to \(path)\n".utf8))
    return writer
}
