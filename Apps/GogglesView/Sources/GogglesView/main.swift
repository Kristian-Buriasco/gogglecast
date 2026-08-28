// Task 2.3/2.4/3.1 app entry point.
//
// This is still NOT the real SwiftUI app (that's Task 3.4+'s job). Through
// Task 3.1, `Apps/GogglesView` is now a real SPM executable package (see
// `Package.swift`'s doc comment for why it moved off a bare `swiftc`
// invocation) whose `main.swift` drives, and is testable ahead of, the
// eventual SwiftUI UI:
//   - `SMAppService.daemon(plistName:).status` registration harness
//     (Task 2.3/2.4, unchanged in behavior from `StubApp/main.swift`).
//   - `HelperClient` (Task 3.1): the real XPC client-connection layer this
//     task builds, exercised here via `--test-client` so it's verifiable
//     from the command line before any UI exists to drive it.
//
// Usage (from inside the assembled .app's Contents/MacOS/, or directly via
// `swift run` from this package during development):
//   ./GogglesView --check-daemon-status   Print SMAppService.daemon status and exit.
//   ./GogglesView --register              Call register(), print status, and (if
//                                          .requiresApproval) open System Settings'
//                                          Login Items & Extensions pane.
//   ./GogglesView --unregister            Call unregister(), print status.
//   ./GogglesView --test-client [secs]    Connect via HelperClient, call
//                                          startStreaming, log fps for `secs`
//                                          seconds (default 10), then
//                                          disconnect and exit.
//
// None of these run by default -- with no recognized flag this prints
// usage and exits 0, so simply building/importing this repo never
// registers anything or opens a connection on a developer's machine.

import Foundation
import ServiceManagement
import GogglesXPC
#if canImport(AppKit)
import AppKit
#endif

let plistName = "com.kburiasco.gogglesview.helper.plist"

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

func printStatus(_ label: String, _ status: SMAppService.Status) {
    print("\(label): \(describe(status)) (rawValue=\(status.rawValue))")
}

/// Deep link to System Settings > General > Login Items & Extensions.
/// Verified working on this machine (macOS 27.0 / 26A5378n) via
/// `open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"`
/// -- see docs/dev-setup.md for how this was confirmed.
let loginItemsSettingsURLString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

func openLoginItemsSettings() {
    guard let url = URL(string: loginItemsSettingsURLString) else {
        print("error: could not construct Login Items settings URL")
        return
    }
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #else
    // Fallback for a non-AppKit build context (shouldn't happen for a macOS
    // app bundle, but keeps this file linkable in odd configurations).
    Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [loginItemsSettingsURLString])
    #endif
    print("Opened System Settings > General > Login Items & Extensions (\(loginItemsSettingsURLString))")
}

let args = CommandLine.arguments
let service = SMAppService.daemon(plistName: plistName)

print("plistName: \(plistName)")

if args.contains("--check-daemon-status") {
    printStatus("SMAppService.daemon(plistName:).status", service.status)
    exit(0)
}

if args.contains("--register") {
    printStatus("[1] BEFORE register()", service.status)
    do {
        try service.register()
        print("[2] register() succeeded")
    } catch {
        print("[2] register() FAILED: \(error)")
        exit(1)
    }
    let status = service.status
    printStatus("[3] AFTER register()", status)
    switch status {
    case .requiresApproval:
        print("Daemon requires user approval. Opening Login Items & Extensions...")
        openLoginItemsSettings()
        print("After approving in System Settings, re-run with --check-daemon-status to confirm .enabled.")
    case .enabled:
        print("Daemon is enabled -- no approval step was required on this run.")
    case .notFound, .notRegistered:
        print("Unexpected post-register() status: \(describe(status)). Investigate before assuming success.")
    @unknown default:
        print("Unexpected/unknown post-register() status (rawValue=\(status.rawValue)).")
    }
    exit(0)
}

if args.contains("--unregister") {
    printStatus("[1] BEFORE unregister()", service.status)
    do {
        try service.unregister()
        print("[2] unregister() succeeded")
    } catch {
        print("[2] unregister() FAILED: \(error)")
        exit(1)
    }
    printStatus("[3] AFTER unregister()", service.status)
    exit(0)
}

if args.contains("--test-client") {
    // Task 3.1's hardware-verification harness (brief point 3): connect via
    // `HelperClient`, call `startStreaming`, log fps for a few seconds, exit.
    // Takes a plain positional seconds argument right after the flag
    // (`--test-client 15`); defaults to 10.
    var seconds: Double = 10
    if let flagIndex = args.firstIndex(of: "--test-client"),
       flagIndex + 1 < args.count,
       let parsed = Double(args[flagIndex + 1]) {
        seconds = parsed
    }

    print("--test-client: connecting to \(helperMachServiceName), running for \(seconds)s...")

    let client = HelperClient()
    client.onConnectionStateChange = { state in
        print("[test-client] connectionState -> \(state)")
    }
    client.onDeviceChanged = { info in
        print("[test-client] deviceChanged -> \(info?.product ?? "nil")")
    }
    client.onHelperStateChanged = { state, detail in
        let name = GogglesState(rawValue: state).map { String(describing: $0) } ?? "unknown(\(state))"
        print("[test-client] helper stateChanged -> \(name)\(detail.map { " [\($0)]" } ?? "")")
    }
    client.onStats = { stats in
        print("[test-client] helper-reported StreamStats: fps=\(stats.fps) bitrate=\(stats.bitrateKbps)kbps drops=\(stats.drops)")
    }

    client.connect()

    // Give the initial connect + protocolVersion round trip a moment, then
    // call startStreaming. If a protocol mismatch is in play, startStreaming
    // will itself refuse loudly (HelperClient.startStreaming's guard) rather
    // than this harness needing its own check.
    //
    // NOTE: every `HelperClient` public closure (`onConnectionStateChange`,
    // every `reply:` completion, etc.) is deliberately delivered on
    // `DispatchQueue.main` (see HelperClient.swift's doc comment -- this is
    // the right call for a future UI consumer that never wants to hop
    // threads itself). That means this harness MUST pump the main run loop
    // for those to ever fire; blocking the main thread on a
    // `DispatchSemaphore` (an earlier version of this file did exactly
    // that) deadlocks forever, because nothing is left to drain
    // `DispatchQueue.main`'s work items. `RunLoop.main.run(until:)` in a
    // loop is the standard fix for mixing GCD .main-queue work with a
    // blocking CLI `main.swift`.
    var finished = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        client.startStreaming { ok, error in
            print("[test-client] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            client.stopStreaming {
                print("[test-client] stopStreaming complete")
                client.disconnect()
                finished = true
            }
        }
    }
    // Hard ceiling so a genuine bug (a reply that never fires) exits this
    // harness eventually instead of hanging forever -- generous margin
    // over the expected `1.0 + seconds + teardown` duration.
    let deadline = Date().addingTimeInterval(seconds + 15)
    while !finished, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !finished {
        print("--test-client: WARNING -- timed out waiting for stopStreaming/disconnect to complete")
    }
    print("--test-client: done")
    exit(0)
}

print("GogglesView stub (Task 2.3/2.4/3.1). Recognized flags:")
print("  --check-daemon-status   print SMAppService.daemon status and exit")
print("  --register              register() the helper daemon as a Login Item")
print("  --unregister            unregister() the helper daemon")
print("  --test-client [secs]    connect via HelperClient, startStreaming, log fps, exit (default 10s)")
exit(0)
