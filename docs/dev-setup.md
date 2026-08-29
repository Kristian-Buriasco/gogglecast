# Dev setup: `GogglesHelper` registration & iteration loop

## Phase 4 prerequisite: Apple Developer Program membership

As of 2026-08-29: **no paid Apple Developer Program membership** on this account yet
(expected to be obtained in the future). Per docs/plan.md's Phase 4 gate and design.md
§8.5, this means Phase 4 (CMIOExtension virtual camera) targets
`systemextensionsctl developer on` (personal-use-only, unsigned/dev-mode system
extension install) rather than a properly notarized, App-Store/notarization-eligible
system extension. Revisit this note and upgrade the install path once a paid membership
is active — the CMIOExtension code itself shouldn't need to change, only the
installation/signing/notarization flow.


Task 2.4. Covers how to register/unregister the privileged root helper
daemon as a `SMAppService` Login Item, how to check its status, how to
iterate on the helper's code without a machine reboot, and how to recover
from a stuck registration.

This all operates on the **stub app** built by
`Apps/GogglesView/build-stub-bundle.sh` (`Apps/GogglesView/build/GogglesView.app`)
— `Contents/MacOS/GogglesView` is a throwaway CLI stub (Task 2.3/2.4), not
the real SwiftUI app (Task 3.x). `Contents/MacOS/GogglesHelper` is the real
helper daemon (Task 2.2, `Helper/GogglesHelper`).

## Prerequisites

- CLT-only toolchain works for all of this (`swift build`, `swiftc`,
  `codesign`) — no `xcodebuild`/`.xcodeproj` needed.
- Team ID on this machine: **`U8LK2QA3FL`** (from an "Apple Development:
  kburiasco@gmail.com" cert, Apple-ID-linked display name embeds
  `S222VMFC76`, which is *not* the Team ID — `codesign -dv`'s
  `TeamIdentifier=` field is the real one, `U8LK2QA3FL`).
- `build-stub-bundle.sh` auto-selects the first valid (non-expired)
  codesigning identity from `security find-identity -v -p codesigning`, or
  falls back to ad-hoc (`--sign -`) if none is valid. Override with
  `GOGGLESVIEW_SIGN_IDENTITY=<hash-or-name>` if you have multiple.
- If `security find-identity -v -p codesigning` shows 0 valid identities,
  renewing/creating a free "Apple Development" cert has **no CLT-only
  path** — it requires Xcode.app, signed into an Apple ID under
  Xcode > Settings > Accounts (Xcode's automatic-signing service talks to
  Apple's developer services). `codesign`/`security` can *use* an existing
  valid identity but cannot *mint* one.

## The stub app's CLI flags

`Contents/MacOS/GogglesView`, built from `Apps/GogglesView/Sources/GogglesView/main.swift`
(Task 3.1 replaced the old `StubApp/` layout with a real SPM package):

| Flag | Effect |
|---|---|
| (none) | Prints usage and exits 0. Building/running this repo never registers anything by accident. |
| `--check-daemon-status` | Prints `SMAppService.daemon(plistName:).status` and exits. Read-only. |
| `--register` | Calls `register()`. If the resulting status is `.requiresApproval`, opens System Settings' Login Items & Extensions pane via the `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` deep link. |
| `--unregister` | Calls `unregister()`, prints status before/after. |

All three of `--register`/`--unregister`/`--check-daemon-status` are
**explicit, deliberate invocations** — none of them run just from building
or importing the repo.

## Checking status three ways

1. **From code** (most reliable — what the app itself sees):
   ```
   Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --check-daemon-status
   ```
2. **`launchctl`** (system truth — whether launchd/SMAppService actually has
   it loaded and, if it's currently spawned, running as root):
   ```
   launchctl print system/com.kburiasco.gogglesview.helper
   ```
   Look for `state = running` and `pid = <n>`. The daemon in this project's
   plist is Mach-service-activated (`MachServices` key, no `KeepAlive`), so
   between client connections it's normal to see `state = not running` even
   while `status` reports `.enabled` — launchd spawns it on demand, on the
   first incoming XPC connection to the Mach service.
3. **`ps`** (is a process actually alive right now, and as whom):
   ```
   ps aux | grep GogglesHelper
   ```
   A live entry shows `root` as the user — confirms it's running privileged,
   not as your login user.

## `SMAppService.Status` values, and the `.notFound` vs `.notRegistered` gotcha

```swift
.notRegistered // rawValue 0
.enabled       // rawValue 1
.requiresApproval // rawValue 2
.notFound      // rawValue 3
```

**Heads-up for future debugging, from Task 2.3's investigation on this
machine (macOS `27.0` / build `26A5378n`, an early/beta build):**
`.notFound` is the correct status for a genuinely never-registered item —
**not** `.notRegistered`, despite what older docs/guides may imply.
`.notRegistered` only appears as a **post-tombstone state**, after an item
has been `register()`'d and then `unregister()`'d at least once. This was
confirmed empirically (Task 2.3 addenda) with a real Team ID cert, after a
full `sudo sfltool resetbtm`, and via a live `register()`/`unregister()`
round-trip:

```
BEFORE register():  notFound       (rawValue=3)
AFTER register():   enabled        (rawValue=1)
AFTER unregister():  notRegistered (rawValue=0)   <- not notFound
```

If you see `.notFound` on a machine that has genuinely never registered
this daemon before, that is expected, not a sign of a broken bundle/plist.

On this OS build/machine, `register()` went straight to `.enabled` with
**no `.requiresApproval` step observed** (Task 2.3 addendum 2 and this
task's own re-verification). The `.requiresApproval` handling in
`--register` (deep link to Login Items & Extensions) is still implemented
per the design brief — a real end user on a different/non-beta machine may
still hit that gate — it's just not something this machine has ever shown.

## The iteration loop (proven, exact steps)

**Editing and rebuilding the helper's file on disk alone is not enough** —
the already-running launchd-managed process keeps running the old binary
image in memory. `launchctl`/`smd` do not watch the binary file for
changes. Getting the launchd-managed instance to pick up a new build
requires cycling registration. This was directly verified on this machine:

1. Edit helper source, e.g. `Helper/GogglesHelper/Sources/GogglesHelper/HelperService.swift`.
2. Rebuild the release binary:
   ```
   ( cd Helper/GogglesHelper && swift build -c release )
   ```
3. Re-run the bundle assembly + signing script (rebuilds the stub app too,
   copies the fresh `GogglesHelper` binary into the bundle, re-signs
   everything):
   ```
   Apps/GogglesView/build-stub-bundle.sh
   ```
4. **Unregister, then re-register** — this is the step that actually makes
   the live launchd job point at the new binary:
   ```
   Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --unregister
   Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --register
   ```
5. The daemon is Mach-service-activated, so it won't actually spawn again
   until the next incoming XPC connection — `ps aux | grep GogglesHelper`
   right after `--register` will typically show nothing yet. Trigger a
   connection (any XPC client, or the real app) and it spawns fresh, with a
   **new PID**, running the just-rebuilt binary.

**Verified with a real code diff, not just a rebuild:** a one-line log
message change in `HelperService.registerConnection` was added, built,
signed, and picked up via steps 1-5 above — confirmed two ways:
- The rebuilt binary's SHA-256 differed from the pre-change binary's.
- After the unregister/register cycle and a fresh client connection, the
  **new PID**'s log line included the new text (`log show --predicate
  'process == "GogglesHelper"' --info --debug`), while the **old PID**'s
  earlier log lines (same session, before the cycle) did not.

The change was reverted and the same rebuild-and-recycle steps repeated to
leave the machine on the clean, committed source.

**No machine reboot was needed at any point in this loop.**

### Why `--unregister`/`--register` and not something lighter

Design §8.4 flags this as a real risk: launchd/`SMAppService` may cache the
loaded binary. `sudo launchctl kickstart`-style restarts were not available
without interactive `sudo` (no passwordless sudo on this machine — see
below), so the unregister/register cycle (which does not require `sudo` —
`SMAppService.daemon.register()`/`.unregister()` are per-user Login Item
APIs, callable from an unprivileged process, per Task 2.3's addendum 2) is
the reliable, always-available path. It is also what actually forces
`smd`/launchd to tear down and reload the job definition, not just restart
the process.

## Clearing a stuck registration

**Normal path:** `unregister()` — via the stub app:
```
Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --unregister
```
Confirm with `--check-daemon-status` (expect `notRegistered`, rawValue 0)
and `ps aux | grep GogglesHelper` (expect no output) / `launchctl print
system/com.kburiasco.gogglesview.helper` (expect "Bad request... Could not
find service").

**Nuclear option:** `sudo sfltool resetbtm`. **This wipes the entire
machine's BackgroundTaskManagement database — every login item / background
task for every app on the machine, not just this project.** Only reach for
this if `unregister()` itself is failing or the daemon is stuck in a state
`unregister()`/`register()` can't clear. Requires interactive `sudo`
(password prompt) — there is no passwordless sudo configured on this
machine.

## Confirming a client actually connects to the live daemon

The Mach service name is `com.kburiasco.gogglesview.helper` (same string
as the plist's `Label` and `MachServices` key, and `GogglesHelper`'s own
`MachService.swift` constant). Any process — no special entitlement or app
bundle required — can connect via
`NSXPCConnection(machServiceName: "com.kburiasco.gogglesview.helper", options: [])`.

Two things a minimal test client must get right or the connection dies
immediately after the first exported-object callback:
- **Export a `GogglesClientProtocol` object**, even a no-op one. The
  daemon's `HelperListenerDelegate` sets
  `newConnection.remoteObjectInterface = NSXPCInterface(with: GogglesClientProtocol.self)`
  and `HelperService.registerConnection` immediately calls back
  `deviceChanged`/`stateChanged` on whatever the client exported — a client
  with no `exportedInterface`/`exportedObject` gets its connection torn
  down right after connecting.
- **Compile `GogglesXPC`'s types (`DeviceInfo` etc.) into a module actually
  named `GogglesXPC`** (`swiftc ... -module-name GogglesXPC`), not some
  other module name (e.g. the default `main` for a loose script). `NSCoder`
  matches `NSSecureCoding` classes by their Swift-mangled name, which
  embeds the module name — a client built as module `main` sends
  `_TtC4main10DeviceInfo` on the wire, which the daemon (expecting
  `_TtC10GogglesXPC10DeviceInfo`) logs as *"received an undecodable
  message (incompatible reply block signature)"* and cancels the
  connection. This was hit and fixed empirically while building this
  task's test client.

Example minimal client flow (see the throwaway client used for this task's
verification, not committed to the repo): connect, call
`protocolVersion(reply:)`, call `currentDeviceInfo(reply:)` — both return
real values from the live process (confirmed against a real running PID,
cross-checked via `ps`/`launchctl` at the same moment).

## Summary of exact commands

```bash
# Build + assemble + sign
( cd Helper/GogglesHelper && swift build -c release )
Apps/GogglesView/build-stub-bundle.sh

# Register / status / unregister
Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --register
Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --check-daemon-status
Apps/GogglesView/build/GogglesView.app/Contents/MacOS/GogglesView --unregister

# System-level checks
launchctl print system/com.kburiasco.gogglesview.helper
ps aux | grep GogglesHelper

# Nuclear reset (machine-wide, all login items, needs interactive sudo)
sudo sfltool resetbtm
```
