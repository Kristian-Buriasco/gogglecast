import os

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: `GogglesHelper` is a daemon, not a CLI tool a human watches
// directly (unlike `gvcli`, which is fine printing plain stderr text) --
// design §4.2 calls it a root `LaunchDaemon`. `os_log`/`Logger` throughout,
// so `log show`/Console.app can reconstruct connection lifecycle, state
// transitions, and errors after the fact. Three categories under one
// subsystem (matching the Mach service name, `MachService.swift`), mirroring
// the USB/XPC/Pipeline split the task brief suggests:
//   - USB:      RNDIS claim/release, device connect/disconnect, SIGTERM.
//   - XPC:      listener/connection lifecycle, subscriber registry, fan-out.
//   - Pipeline: handshake/state-machine transitions, stats.
// ─────────────────────────────────────────────────────────────────────────

enum Logging {
    static let subsystem = "com.kburiasco.gogglesview.helper"

    static let usb = Logger(subsystem: subsystem, category: "USB")
    static let xpc = Logger(subsystem: subsystem, category: "XPC")
    static let pipeline = Logger(subsystem: subsystem, category: "Pipeline")
}
