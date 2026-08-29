import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: third call site for the same Team-ID-prefixed Mach service name
// as `Helper/GogglesHelper/Sources/GogglesHelper/MachService.swift` and
// `Apps/GogglesView/Sources/GogglesView/MachService.swift`. All three MUST
// agree -- see those files' doc comments for the full contract. This is
// exactly the string the sandboxed extension attempts to `bootstrap_look_up`
// via `NSXPCConnection(machServiceName:options:)`; the whole spike is
// answering whether that lookup is permitted from inside this process's
// sandbox.
// ─────────────────────────────────────────────────────────────────────────
let helperMachServiceName = "U8LK2QA3FL.com.kburiasco.gogglesview.helper"
