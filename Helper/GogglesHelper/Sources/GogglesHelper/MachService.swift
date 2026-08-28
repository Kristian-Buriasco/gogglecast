import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: the Mach service name `GogglesHelper --xpc` listens on.
//
// design §4.4 (Change 2) already commits to the exact form:
//
//   > one Mach service, name `<TeamID>.com.kburiasco.gogglesview.helper`,
//   > declared in the daemon plist and listed in the app group shared by
//   > app, helper and extension.
//
// `<TeamID>` isn't wired up yet -- this task builds and runs the daemon
// unsigned, directly with `sudo`, with no code-signing/entitlements/app-group
// story in place (that's packaging, task 2.3+). Using the unprefixed base
// string here for now is deliberate, not an oversight: it's the exact
// suffix the design doc already fixes, so task 2.3's launchd plist only has
// to prepend the team ID (or leave it as-is if the app group turns out not
// to require the prefix in practice -- verify against the design doc's
// §8.4 SMAppService section when that task starts).
//
// **Whoever writes task 2.3's launchd plist (`MachServices` key) and
// whoever writes the app-side `NSXPCConnection(machServiceName:options:)`
// call MUST use this exact string (or its final `<TeamID>`-prefixed form,
// updated here and only here) -- all three call sites have to agree.**
// ─────────────────────────────────────────────────────────────────────────
let machServiceName = "com.kburiasco.gogglesview.helper"
