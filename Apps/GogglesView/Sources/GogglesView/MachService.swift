import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1: the app-side counterpart of
// `Helper/GogglesHelper/Sources/GogglesHelper/MachService.swift`. That
// file's own doc comment is explicit about the contract:
//
//   "Whoever writes task 2.3's launchd plist (`MachServices` key) and
//   whoever writes the app-side `NSXPCConnection(machServiceName:options:)`
//   call MUST use this exact string (or its final `<TeamID>`-prefixed
//   form, updated here and only here) -- all three call sites have to
//   agree."
//
// This is that app-side call site (`HelperClient.swift`). Verified against
// the helper's own file (not assumed) before writing this: the string is
// unprefixed, `com.kburiasco.gogglesview.helper`, matching both the
// helper's own listener and the live `com.kburiasco.gogglesview.helper.plist`
// LaunchDaemon plist installed by `SMAppService.daemon` (Task 2.3/2.4,
// currently running as root on this machine).
//
// Not shared via `GogglesXPC` itself: `GogglesXPC` is meant to stay a
// minimal, dependency-free protocol/value-type surface (see that package's
// own doc comments); the Mach service name is bootstrap/deployment
// plumbing, not part of the RPC surface, so it stays duplicated at each of
// the three call sites (helper's own listener, the LaunchDaemon plist, and
// here) exactly as the helper's file already does, rather than growing
// `GogglesXPC`'s scope to cover it.
// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: Team-ID-prefixed (see the matching comment/update in
// `Helper/GogglesHelper/Sources/GogglesHelper/MachService.swift`) -- the
// sandboxed CMIOExtension spike needs this exact prefixed name to exercise
// the sandbox's documented mach-lookup exception for names beginning with
// the requesting process's own Team ID.
public let helperMachServiceName = "U8LK2QA3FL.com.kburiasco.gogglesview.helper"
