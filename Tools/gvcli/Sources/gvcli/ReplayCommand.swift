import Foundation
import GogglesProtocol

/// `gvcli replay <capture-file> [--out <path>] [--stats]`: the offline
/// path -- same pipeline as `gvcli stream`, but driven by `MockTransport`
/// over a `.gvcap` capture file instead of live hardware. No root needed:
/// `MockTransport` never touches USB.
///
/// Pacing is always `.realTime` (replays at the capture's original
/// inter-frame timing) rather than `.accelerated`/`.immediate`: this
/// command's fps/bitrate stats are only meaningful measured against
/// real-time playback, and task 1.7's brief specifically calls out
/// `.realTime` (or near-real-time) as the right choice for that reason.
func runReplayCommand(args: [String]) async throws {
    var outPath: String?
    var stats = false
    var capturePath: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out":
            i += 1
            guard i < args.count else { throw GVCLIError.message("--out requires a path argument") }
            outPath = args[i]
        case "--stats":
            stats = true
        default:
            if capturePath == nil, !args[i].hasPrefix("--") {
                capturePath = args[i]
            } else {
                throw GVCLIError.message("Unknown argument '\(args[i])' for 'replay'. Usage: gvcli replay <capture-file> [--out <path>] [--stats]")
            }
        }
        i += 1
    }
    guard let capturePath else {
        throw GVCLIError.message("'replay' requires a <capture-file> argument. Usage: gvcli replay <capture-file> [--out <path>] [--stats]")
    }

    FileHandle.standardError.write(Data("[gvcli] Replaying \(capturePath) via MockTransport (real-time pacing)...\n".utf8))
    let transport = try MockTransport(capturePath: URL(fileURLWithPath: capturePath), pacing: .realTime)
    try await runPipeline(transport: transport, outPath: outPath, stats: stats)
}
