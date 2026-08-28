import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: `GogglesHelper` -- the daemon binary wrapping the Phase 1
// protocol core (see task-2.2-brief.md / design §4.2, §5.5, §8.4).
//
//   sudo ./GogglesHelper --stdout   -- Phase-1-equivalent CLI mode.
//   sudo ./GogglesHelper --xpc      -- NSXPCListener daemon mode.
//
// Modeled directly on `gvcli`'s `main.swift` (subcommand dispatch, plain
// stderr usage text, `try await` at top level for `--stdout`'s async
// pipeline).
// ─────────────────────────────────────────────────────────────────────────

func printUsage() {
    let usage = """
    GogglesHelper -- GogglesView's privileged root daemon (design §4.2)

    USAGE:
      sudo ./GogglesHelper --stdout
          Phase-1-equivalent mode: connect to the goggles over USB/RNDIS,
          run the full receive pipeline, and write raw Annex-B H.264 to
          stdout. No XPC. Requires root to claim the goggles' USB
          interfaces on macOS. This is deliberately how protocol
          regressions are diagnosed without the XPC layer in the way
          (design §8.4).

      sudo ./GogglesHelper --xpc
          Start an NSXPCListener on the Mach service '\(machServiceName)',
          serving GogglesHelperProtocol to any number of fanned-out
          subscribers (design §5.5). The hardware is claimed lazily, on
          the first subscriber's startStreaming call, and released 5s
          after the last one disconnects.
    """
    print(usage)
}

let arguments = CommandLine.arguments
let mode = arguments.count >= 2 ? arguments[1] : nil

switch mode {
case "--stdout":
    do {
        try await runStdoutMode()
    } catch {
        FileHandle.standardError.write(Data("[GogglesHelper] Error: \(error)\n".utf8))
        exit(1)
    }
case "--xpc":
    runXPCMode()
case "-h", "--help", "help":
    printUsage()
case .some(let unknown):
    FileHandle.standardError.write(Data("[GogglesHelper] Unknown argument '\(unknown)'\n\n".utf8))
    printUsage()
    exit(1)
case .none:
    printUsage()
    exit(1)
}
