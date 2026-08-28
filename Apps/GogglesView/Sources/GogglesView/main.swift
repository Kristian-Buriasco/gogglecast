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
//   ./GogglesView --run                   Task 3.5: real end-to-end -- connect,
//                                          startStreaming, and show the real
//                                          GogglesConnectionView (including the
//                                          real .waitingForKeyframe card) with a
//                                          temporary "Goggles > Reconnect" menu.
//
// None of these run by default -- with no recognized flag this prints
// usage and exits 0, so simply building/importing this repo never
// registers anything or opens a connection on a developer's machine.

import Foundation
import ServiceManagement
import GogglesXPC
#if canImport(AppKit)
import AppKit
import SwiftUI
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

#if canImport(AppKit)
if args.contains("--live-view") {
    // Task 3.3's hardware-verification harness: not the real SwiftUI app
    // shell (Task 3.4/3.6's job -- see GogglesVideoView.swift's doc
    // comment), just enough AppKit scaffolding to put a live
    // AVSampleBufferDisplayLayer-backed window on screen so decoded video
    // can be visually confirmed against real goggles hardware. Exits when
    // the window is closed.
    print("--live-view: connecting to \(helperMachServiceName) and opening a video window...")

    let client = HelperClient()
    let session = DecodeSession()
    session.onDroppedSample = { error in
        print("[live-view] dropped sample: \(error)")
    }
    session.onTeardown = {
        print("[live-view] decode session torn down after \(DecodeSession.maxConsecutiveFailures) consecutive failures -- waiting for next parameter set")
    }
    client.onNALUnit = { data, nalType, isParameterSet, hostTime in
        session.handle(nalData: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }
    client.onConnectionStateChange = { state in
        print("[live-view] connectionState -> \(state)")
    }
    client.onHelperStateChanged = { state, detail in
        let name = GogglesState(rawValue: state).map { String(describing: $0) } ?? "unknown(\(state))"
        print("[live-view] helper stateChanged -> \(name)\(detail.map { " [\($0)]" } ?? "")")
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let hostingController = NSHostingController(rootView: GogglesVideoView(session: session))
    let window = NSWindow(contentViewController: hostingController)
    window.title = "GogglesView -- live-view (Task 3.3 hardware verification)"
    window.setContentSize(NSSize(width: 960, height: 540))
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    window.center()
    window.makeKeyAndOrderFront(nil)

    let delegate = LiveViewAppDelegate()
    app.delegate = delegate

    client.connect()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        client.startStreaming { ok, error in
            print("[live-view] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }

    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
if args.contains("--run") {
    // Task 3.5: the first real end-to-end harness -- unlike `--live-view`
    // (Task 3.3, which drives `GogglesVideoView` directly off a raw
    // `HelperClient` and never touches the state machine at all) and
    // `--force-state` (Task 3.4, which never opens a real XPC connection),
    // this wires a real `HelperClient` through the real
    // `GogglesConnectionCoordinator` into the real `GogglesConnectionView`
    // -- i.e. exactly what a user would see, including the real
    // `.waitingForKeyframe` card this task builds. Still not the real app
    // shell (no dock icon curation, no persistent menu bar item -- Task
    // 3.6's job); the temporary "Goggles > Reconnect" menu item this task's
    // brief calls for lives here.
    print("--run: connecting to \(helperMachServiceName) and opening the real connection view...")

    let client = HelperClient()
    let coordinator = GogglesConnectionCoordinator(client: client)
    let session = DecodeSession()
    session.onDroppedSample = { error in
        print("[run] dropped sample: \(error)")
    }
    session.onTeardown = {
        print("[run] decode session torn down after \(DecodeSession.maxConsecutiveFailures) consecutive failures -- waiting for next parameter set")
    }
    // `coordinator.onNALUnit`, not `client.onNALUnit` directly -- the
    // coordinator already owns `client.onNALUnit` itself (watchdog-activity
    // bookkeeping) and forwards raw NAL data through its own `onNALUnit`
    // passthrough precisely so a real decode consumer can sit alongside
    // that without clobbering it (see that property's doc comment).
    coordinator.onNALUnit = { data, nalType, isParameterSet, hostTime in
        session.handle(nalData: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let hostingController = NSHostingController(rootView: GogglesConnectionView(coordinator: coordinator, session: session))
    let window = NSWindow(contentViewController: hostingController)
    window.title = "GogglesView"
    window.setContentSize(NSSize(width: 480, height: 420))
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    window.center()
    window.makeKeyAndOrderFront(nil)

    // Temporary "Goggles > Reconnect" menu item (task brief: "a menu item
    // is a fine temporary home for this -- Task 3.6 will build the real
    // menu bar and can relocate it"). Reachable at any time regardless of
    // `uiState`, per design §8.1.
    let reconnectTarget = MenuActionTarget { coordinator.reconnect() }
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit GogglesView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let gogglesMenuItem = NSMenuItem()
    mainMenu.addItem(gogglesMenuItem)
    let gogglesMenu = NSMenu(title: "Goggles")
    let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(MenuActionTarget.invoke), keyEquivalent: "r")
    reconnectItem.target = reconnectTarget
    gogglesMenu.addItem(reconnectItem)
    gogglesMenuItem.submenu = gogglesMenu
    app.mainMenu = mainMenu

    let delegate = LiveViewAppDelegate()
    app.delegate = delegate

    client.connect()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        client.startStreaming { ok, error in
            print("[run] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }

    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
if args.contains("--force-state") {
    // Task 3.4 exit criterion ("verified by forcing each one"): opens a
    // window showing `GogglesConnectionView` with its `uiState` directly
    // overridden via `GogglesConnectionCoordinator.forceState(_:)` -- no
    // XPC connection, no helper process, no goggles hardware needed. Lets
    // every one of the 9 states be visually inspected on demand.
    //
    // Usage: ./GogglesView --force-state <name>
    //   name is one of: noHelper, noDevice, claiming, claimFailed,
    //   resolving, handshaking, waitingForKeyframe, live, stalled
    guard let flagIndex = args.firstIndex(of: "--force-state"), flagIndex + 1 < args.count else {
        print("--force-state requires a state name, e.g. --force-state claimFailed")
        print("valid names: \(GogglesUIStateKind.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }
    let name = args[flagIndex + 1]
    guard let forced = forcedState(named: name) else {
        print("unrecognized state name '\(name)'. valid names: \(GogglesUIStateKind.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(1)
    }

    print("--force-state \(name): opening a window with uiState forced to \(forced)...")

    let client = HelperClient()
    let coordinator = GogglesConnectionCoordinator(client: client, startWatchdog: false)
    let session = DecodeSession()
    // Sample device info so the card has something to show for every
    // state that displays it (`.claiming` onward) -- a real connection
    // would populate this via `deviceChanged`, which never fires here
    // since `client.connect()` is deliberately never called.
    coordinator.forceState(forced)

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let hostingController = NSHostingController(rootView: GogglesConnectionView(coordinator: coordinator, session: session))
    let window = NSWindow(contentViewController: hostingController)
    window.title = "GogglesView -- --force-state \(name) (Task 3.4 manual verification)"
    window.setContentSize(NSSize(width: 480, height: 360))
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    window.center()
    window.makeKeyAndOrderFront(nil)

    let delegate = LiveViewAppDelegate()
    app.delegate = delegate

    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
#endif

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

print("GogglesView stub (Task 2.3/2.4/3.1/3.3/3.4). Recognized flags:")
print("  --check-daemon-status   print SMAppService.daemon status and exit")
print("  --register              register() the helper daemon as a Login Item")
print("  --unregister            unregister() the helper daemon")
print("  --test-client [secs]    connect via HelperClient, startStreaming, log fps, exit (default 10s)")
print("  --live-view             open a minimal AVSampleBufferDisplayLayer window and stream decoded video")
print("  --force-state <name>    open GogglesConnectionView with uiState forced to <name> (Task 3.4 manual verification)")
print("  --run                   real end-to-end: connect, startStreaming, show GogglesConnectionView + Goggles>Reconnect menu (Task 3.5 hardware verification)")
exit(0)

#if canImport(AppKit)
/// Terminates `--live-view`'s `NSApplication.run()` loop when its one
/// window is closed, so the harness process exits instead of hanging as a
/// windowless background app.
final class LiveViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Task 3.5: `NSMenuItem.action` needs an `@objc` selector on some target
/// object -- this is the smallest thing that adapts a plain Swift closure
/// (`--run`'s "Goggles > Reconnect" item) to that, without inventing a
/// bigger menu-building abstraction that's Task 3.6's job, not this one's.
final class MenuActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
    }
    @objc func invoke() {
        action()
    }
}

/// Maps `--force-state`'s string argument to a `GogglesUIState`, using
/// representative sample associated data (a real interfaceClaimFailed
/// diagnostic, a plausible elapsed-seconds value) so each forced state
/// renders exactly as it would in practice, not with placeholder zeros.
func forcedState(named name: String) -> GogglesUIState? {
    switch name {
    case "noHelper": return .noHelper(reason: nil)
    case "noDevice": return .noDevice
    case "claiming": return .claiming
    case "claimFailed": return .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed)
    case "claimFailed-arp": return .claimFailed(reason: GogglesDiagnostics.arpTimeout)
    case "resolving": return .resolving
    case "handshaking": return .handshaking(elapsedSeconds: 3)
    case "waitingForKeyframe": return .waitingForKeyframe
    case "live": return .live
    case "stalled": return .stalled
    default: return nil
    }
}
#endif
