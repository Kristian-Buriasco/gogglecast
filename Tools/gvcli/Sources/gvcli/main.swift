import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 1.7: gvcli, the Phase 1 exit-gate parity harness CLI. Three
// subcommands (see task-1.7-brief.md):
//
//   gvcli info                                   -- device info only
//   gvcli stream --out <path> [--stats]           -- live hardware
//   gvcli replay <capture-file> [--out <path>] [--stats]  -- offline (.gvcap)
// ─────────────────────────────────────────────────────────────────────────

func printUsage() {
    let usage = """
    gvcli -- GogglesView protocol-port test/parity harness

    USAGE:
      gvcli info
          Connect over USB/RNDIS, print device info (product, serial,
          bcdDevice, bus/address), and exit. No video pipeline.

      gvcli stream --out <path> [--stats] [--ack-mode frame|window]
          Connect to real hardware over USB/RNDIS, run the full receive
          pipeline, and write raw Annex-B H.264 to <path> (a regular file
          or a FIFO -- opening a FIFO blocks until a reader attaches).
          Requires root to claim the goggles' USB interfaces on macOS.
          --ack-mode window: EXPERIMENTAL cumulative receive-window acks
          (also selectable via GOGGLES_ACK_MODE=window). Default 'frame'.

      gvcli replay <capture-file> [--out <path>] [--stats]
          Same pipeline, driven by a .gvcap capture file via MockTransport
          instead of live hardware. No root required. --out is optional;
          omit it to only exercise/measure the pipeline (e.g. --stats
          alone) without writing output.

    In both stream/replay, --stats prints one [stats] line per second to
    stderr with fps, bitrate, and drop-count (per-second and cumulative),
    plus a [proto] line: inbound packet counts by type, retransmitted video
    packets, and the goggles' own type-2 send window (gwin) / resend state.
    """
    print(usage)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    printUsage()
    exit(1)
}

let subcommand = arguments[1]
let rest = Array(arguments.dropFirst(2))

do {
    switch subcommand {
    case "info":
        try await runInfoCommand()
    case "stream":
        try await runStreamCommand(args: rest)
    case "replay":
        try await runReplayCommand(args: rest)
    case "-h", "--help", "help":
        printUsage()
    default:
        FileHandle.standardError.write(Data("[gvcli] Unknown subcommand '\(subcommand)'\n\n".utf8))
        printUsage()
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("[gvcli] Error: \(error)\n".utf8))
    exit(1)
}
