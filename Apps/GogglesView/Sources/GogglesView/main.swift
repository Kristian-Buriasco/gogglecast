// GogglesView app entry point.
//
// Task 3.6: this file's default (no-argument) path is now v1's real,
// shippable launch behavior -- a plain double-click of `GogglesView.app`
// (or running `Contents/MacOS/GogglesView` with no flags) connects to the
// helper, opens the real `GogglesConnectionView` window (16:9 aspect-ratio
// constrained, fullscreen-capable), and puts up a persistent `NSStatusItem`
// menu bar presence (state glyph, Reconnect, show/hide window, Quit -- see
// `MenuBarController.swift`). Everything through Task 3.5 built up to this
// piece by piece but always behind an explicit flag (`--test-client`,
// `--live-view`, `--force-state`, `--run`); this task is what finally makes
// the no-flags path the real app instead of a usage printout.
//
// The dev/debug flags below remain, for development use, and `--run`
// specifically remains a named synonym for the same default real-app path
// (useful for scripting/documentation that wants to be explicit about
// intent rather than relying on "no arguments"):
//   ./GogglesView                         Default: the real app (see above).
//   ./GogglesView --run                   Explicit synonym for the above.
//   ./GogglesView --check-daemon-status   Print SMAppService.daemon status and exit.
//   ./GogglesView --register              Call register(), print status, and (if
//                                          .requiresApproval) open System Settings'
//                                          Login Items & Extensions pane.
//   ./GogglesView --unregister            Call unregister(), print status.
//   ./GogglesView --install-camera-extension
//                                          Task 4.1 spike: submit an
//                                          OSSystemExtensionRequest for the
//                                          throwaway GogglesCamera bundle.
//   ./GogglesView --test-client [secs]    Connect via HelperClient, call
//                                          startStreaming, log fps for `secs`
//                                          seconds (default 10), then
//                                          disconnect and exit.
//   ./GogglesView --live-view             Task 3.3 hardware-verification harness:
//                                          bypasses the state machine entirely.
//   ./GogglesView --force-state <name>    Task 3.4 manual-verification harness:
//                                          force uiState without any XPC connection.
//
// An unrecognized `--something` flag prints usage and exits 1 (does not
// fall through to the real app) -- see the bottom of this file.

import Foundation
import ServiceManagement
import GogglesXPC
#if canImport(AppKit)
import AppKit
import SwiftUI
import Combine
#endif

// task-gui-v2: `plistName`/`describe(_:)` used to live here as this file's
// own top-level declarations (Task 2.4). Both now come from
// `HelperRegistration` (see that file's doc comment) so the CLI harness
// below and the Settings screen's Launch-at-login toggle/Re-register button
// share one real implementation instead of three copies of the same
// `SMAppService.daemon(plistName:)` logic. `plistName` kept as a local alias
// so every line below this point (and its printed output) is unchanged.
let plistName = HelperRegistration.plistName
let describe = HelperRegistration.describe

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
let service = HelperRegistration.service

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

if args.contains("--install-camera-extension") {
    // Task 4.1: THROWAWAY spike installer -- see CameraExtensionInstaller.swift's
    // doc comment. Runs the process for up to 60s waiting on the async
    // OSSystemExtensionRequest callbacks (requestNeedsUserApproval can fire
    // and then require a human to act in System Settings, so this doesn't
    // just exit immediately).
    let installer = CameraExtensionInstaller()
    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
    installer.install { ok in
        succeeded = ok
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 60)
    print("--install-camera-extension: done (succeeded=\(succeeded))")
    exit(succeeded ? 0 : 1)
}

#if canImport(AppKit)

/// Top-level retain point for the real app shell's objects
/// (`launchMainWindow`), since `--run`'s original
/// `withExtendedLifetime(...) { app.run() }` pattern no longer applies --
/// see that function's doc comment.
var mainWindowRetainedObjects: [Any] = []

/// Stops streaming and closes everything `launchMainWindow` created (back to picker).
var mainWindowTeardown: (() -> Void)?

/// Bridges `DevicePickerCoordinator.$state`'s Combine publisher to a plain
/// closure fired exactly once, the first time `state` becomes `.selected`.
/// A small dedicated type (not an inline `Combine.sink` at the call site)
/// so it has a stable identity `withExtendedLifetime`/a retained array can
/// hold onto for the picker phase's duration.
/// Dev/debug-harness-only helper (`--live-view`, `--test-client`): polls
/// `enumerateDevices` on a 0.5s cadence until a candidate appears (or
/// `timeout` elapses), then calls `completion` with the first one's
/// `deviceId` -- `nil` on timeout. Not used by the real `--run` app shell,
/// which uses the real picker (`DevicePickerCoordinator`) instead; this is
/// the minimum needed to keep these two pre-existing hardware-verification
/// harnesses working against the multi-device-picker protocol change.
func pollFirstAvailableDeviceId(client: HelperClient, timeout: TimeInterval = 15, completion: @escaping (String?) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func attempt() {
        client.enumerateDevices { infos in
            if let first = infos.first {
                completion(first.deviceId)
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt)
            } else {
                completion(nil)
            }
        }
    }
    attempt()
}

var cursorAutoHider: CursorAutoHider?

final class PickerSelectionObserver {
    private var cancellable: AnyObject?

    init(picker: DevicePickerCoordinator, onSelected: @escaping (String) -> Void) {
        var fired = false
        let sink = picker.$state.sink { state in
            guard !fired, case .selected(let deviceId) = state else { return }
            fired = true
            onSelected(deviceId)
        }
        cancellable = sink
    }
}

if let idx = args.firstIndex(of: "--record-test") {
    // Dev harness: records N seconds from the first connected goggles with the
    // real DecodeSession + Recorder, prints the file path, exits.
    let seconds = idx + 1 < args.count ? (Double(args[idx + 1]) ?? 10) : 10
    let client = HelperClient()
    let session = DecodeSession()
    let recorder = Recorder()
    session.addConsumer(recorder)
    var firstHost: UInt64?
    var firstApp: UInt64?
    var seen = 0
    client.onNALUnit = { data, nalType, isParameterSet, hostTime in
        if !isParameterSet, seen < 80 {
            let now = mach_absolute_time()
            if firstHost == nil { firstHost = hostTime; firstApp = now }
            var tb = mach_timebase_info(numer: 0, denom: 0); mach_timebase_info(&tb)
            let hMs = Double(hostTime &- firstHost!) * Double(tb.numer) / Double(tb.denom) / 1e6
            let aMs = Double(now &- firstApp!) * Double(tb.numer) / Double(tb.denom) / 1e6
            print("[record-test] nal#\(seen) type=\(nalType) helperMs=\(Int(hMs)) appMs=\(Int(aMs))")
            seen += 1
        }
        session.handle(nalData: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }
    client.connect()
    pollFirstAvailableDeviceId(client: client, timeout: 20) { deviceId in
        guard let deviceId else { print("[record-test] no device found"); exit(2) }
        client.startStreaming(deviceId: deviceId) { ok, error in
            print("[record-test] startStreaming ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
            guard ok else { exit(3) }
            do { try recorder.start() } catch { print("[record-test] start failed: \(error)"); exit(4) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                recorder.stop { url in
                    print("[record-test] file: \(url?.path ?? "nil") lastError=\(recorder.lastError ?? "nil")")
                    client.stopStreaming(deviceId: deviceId) { exit(url == nil ? 5 : 0) }
                }
            }
        }
    }
    RunLoop.main.run()
}
if args.contains("--battery-test") {
    // Dev harness: streams the first connected goggles until the helper
    // reports a battery reading (unknown/-1 pushes are skipped), prints it, exits.
    let client = HelperClient()
    var done = false
    client.connect()
    pollFirstAvailableDeviceId(client: client, timeout: 20) { deviceId in
        guard let deviceId else { print("[battery-test] no device found"); exit(2) }
        func finish(_ code: Int32) {
            guard !done else { return }
            done = true
            client.stopStreaming(deviceId: deviceId) { exit(code) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(code) }
        }
        client.onBatteryChanged = { percent in
            guard let percent else { return }
            print("[battery-test] percent=\(percent)")
            finish(0)
        }
        client.startStreaming(deviceId: deviceId) { ok, error in
            print("[battery-test] startStreaming ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
            guard ok else { exit(3) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            guard !done else { return }
            print("[battery-test] timed out waiting for a battery reading")
            finish(1)
        }
    }
    RunLoop.main.run()
}
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
    // Multi-device picker design item 5: `startStreaming` now needs a
    // `deviceId` -- this dev/debug harness (unlike the real app's
    // `DevicePickerCoordinator`) just polls for the first available
    // candidate and streams it, since it predates and isn't the picker UX
    // itself (design item 7's picker only lives in the `--run` path).
    pollFirstAvailableDeviceId(client: client) { deviceId in
        guard let deviceId else {
            print("[live-view] no device found after polling; giving up on startStreaming")
            return
        }
        client.startStreaming(deviceId: deviceId) { ok, error in
            print("[live-view] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }

    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}
if args.contains("--run") || !args.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    // Task 3.6: this is now v1's real default launch behavior, not just
    // another debug flag -- the app bundle's actual entry point (no
    // arguments, e.g. a normal Dock/Finder double-click) falls into this
    // exact same branch as the explicit `--run` flag. `--run` is kept as an
    // explicit, named synonym for development use (matches every other
    // flag in this file's convention of being nameable from a terminal),
    // but it is no longer the *only* way to reach this code path.
    //
    // History: originally Task 3.5's `--run` harness (first real
    // end-to-end wiring -- unlike `--live-view`, Task 3.3, which drives
    // `GogglesVideoView` directly off a raw `HelperClient` and never
    // touches the state machine, and `--force-state`, Task 3.4, which never
    // opens a real XPC connection). This task (3.6) promotes it to the
    // default path and adds the real app shell around it: a persistent
    // `NSStatusItem` menu bar presence (`MenuBarController` -- state glyph,
    // Reconnect relocated here from its temporary home as a "Goggles" main
    // -menu item, show/hide window), a 16:9 aspect-ratio window constraint,
    // and fullscreen support.
    print("GogglesView: connecting to \(helperMachServiceName) and opening the real connection view...")

    let client = HelperClient()

    // Multi-device picker design item 7: a device-selection step precedes
    // the existing state machine. `launchMainWindow(deviceId:)` below is
    // everything this branch used to do unconditionally (Task 3.6) --
    // untouched, just now parameterized by the deviceId the picker
    // resolved, and called once instead of unconditionally at startup.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // Settings fix (post-multi-device UX gap): built ONCE, here, before the
    // picker -- not inside `launchMainWindow` as originally shipped.
    // Registering/re-registering the helper daemon is exactly the thing a
    // user needs to do *before* a device can show up at all, so gating
    // Settings behind device selection made it unreachable at precisely
    // the moment it's most needed. `setReconnectHandler` below wires the
    // Reconnect button once a real coordinator exists post-selection; it
    // stays disabled (not absent) before that, same "disabled reads more
    // honest than silently missing" reasoning as the footer button itself.
    let settingsWindowController = SettingsWindowController()

    // Same fix, for the real top-of-screen app menu bar (App/File/Window --
    // see the full construction and its own doc comment further down,
    // inside `launchMainWindow`... no: moved up here too, for the same
    // reason as Settings. `activeCoordinator` starts `nil` and is set once
    // `launchMainWindow` runs; the File menu's "Reconnect" item is disabled
    // until then instead of silently no-op'ing.
    var activeCoordinator: GogglesConnectionCoordinator?
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About GogglesView", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit GogglesView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let settingsMenuTarget = MenuActionTarget { settingsWindowController.show() }
    let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(MenuActionTarget.invoke), keyEquivalent: ",")
    settingsMenuItem.target = settingsMenuTarget
    fileMenu.addItem(settingsMenuItem)
    let reconnectMenuTarget = MenuActionTarget { activeCoordinator?.reconnect() }
    let reconnectMenuItem = NSMenuItem(title: "Reconnect", action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
    reconnectMenuItem.target = reconnectMenuTarget
    reconnectMenuItem.isEnabled = false
    fileMenu.addItem(reconnectMenuItem)
    fileMenuItem.submenu = fileMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    let fullScreenItem = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreenItem.keyEquivalentModifierMask = [.control, .command]
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowMenuItem.submenu = windowMenu

    app.mainMenu = mainMenu
    app.windowsMenu = windowMenu

    let pickerDelegate = LiveViewAppDelegate()
    var pickerRetained: [Any] = []

    // Mutually recursive: the picker launches the main window, whose "Devices"
    // button presents a fresh picker again. The new picker window is shown
    // before the main window closes so the app never has zero windows.
    func presentPicker() {
        let picker = DevicePickerCoordinator(client: client)
        let pickerHostingController = NSHostingController(rootView: DevicePickerView(
            picker: picker,
            onOpenSettings: { settingsWindowController.show() }
        ))
        pickerHostingController.sizingOptions = []
        let pickerWindow = NSWindow(contentViewController: pickerHostingController)
        pickerWindow.title = "GogglesView"
        pickerWindow.setContentSize(NSSize(width: 720, height: 520))
        pickerWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        applyCustomTitleBarChrome(to: pickerWindow)
        pickerWindow.center()
        pickerWindow.makeKeyAndOrderFront(nil)
        app.delegate = pickerDelegate

        var didLaunchMain = false
        let observer = PickerSelectionObserver(picker: picker) { deviceId in
            guard !didLaunchMain else { return }
            didLaunchMain = true
            // Order the main window in BEFORE closing the picker so the app
            // never sees a zero-window state (the picker delegate quits on
            // last window closed).
            let coordinator = launchMainWindow(
                deviceId: deviceId, client: client, app: app,
                settingsWindowController: settingsWindowController,
                onBack: { goBackToPicker() }
            )
            activeCoordinator = coordinator
            reconnectMenuItem.isEnabled = true
            pickerWindow.close()
        }
        pickerRetained = [observer, pickerWindow, pickerHostingController, picker]
        picker.resumeIfConnected()
    }

    func goBackToPicker() {
        presentPicker()
        mainWindowTeardown?()
        mainWindowTeardown = nil
        activeCoordinator = nil
        reconnectMenuItem.isEnabled = false
    }

    presentPicker()

    client.connect()
    app.activate(ignoringOtherApps: true)
    // `app.run()` is called exactly once for this whole process (both the
    // picker phase above and `launchMainWindow`'s real app shell below run
    // inside this same call -- `launchMainWindow` reconfigures windows/menu
    // bar from a main-queue callback fired while this loop is already
    // spinning, it never calls `app.run()` itself). `observer` is kept
    // alive via `withExtendedLifetime` for the same reason every other
    // menu-bar/delegate object in this file needs an explicit owner.
    withExtendedLifetime((pickerDelegate, settingsWindowController, settingsMenuTarget, reconnectMenuTarget)) {
        app.run()
    }
    exit(0)
}

/// Multi-device picker design item 7: everything Task 3.6's `--run` branch
/// used to do unconditionally at startup -- the real app shell (menu bar,
/// aspect-ratio+fullscreen window, main menu) -- now deferred until
/// `DevicePickerCoordinator` has resolved a `deviceId` (immediately, with
/// no user action, for the 0/1-device regression case; after a picker tap
/// for 2+). Unchanged from the original `--run` body except: `coordinator`
/// is now constructed with the resolved `deviceId`, the old 1s-delayed
/// `client.connect()`/`startStreaming` bootstrap is replaced by an
/// immediate `startStreaming(deviceId:)` call (the client is already
/// connected by this point -- reaching here required a successful
/// `enumerateDevices` round trip), and this function does not call
/// `app.run()`/`exit(0)` itself (the caller's single `app.run()` call,
/// already in progress, covers this too).
@discardableResult
func launchMainWindow(
    deviceId: String, client: HelperClient, app: NSApplication,
    settingsWindowController: SettingsWindowController,
    onBack: (() -> Void)? = nil
) -> GogglesConnectionCoordinator {
    let coordinator = GogglesConnectionCoordinator(client: client, deviceId: deviceId)
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

    // Settings fix: `settingsWindowController` is now passed in, built
    // once at app launch (before the picker) -- not rebuilt here. Just
    // wire the Reconnect button it's been sitting without since launch.
    settingsWindowController.setReconnectHandler { coordinator.reconnect() }
    // Capture window for OBS Window Capture. Setting the handler also applies the saved
    // preference, so it opens at launch if enabled. The closure retains the controller.
    let captureWindowController = CaptureWindowController(session: session)
    settingsWindowController.setCaptureWindowHandler { enabled, onTop in
        captureWindowController.keepOnTop = onTop
        if enabled { captureWindowController.show() } else { captureWindowController.hide() }
    }

    let hostingController = NSHostingController(rootView: GogglesConnectionView(
        coordinator: coordinator,
        session: session,
        onOpenSettings: { settingsWindowController.show() },
        onBack: onBack
    ))
    // Real bug found during Task 3.5's window-sizing complaint while
    // verifying the decode fix live: `NSHostingController`'s default
    // `sizingOptions` (`.standardBounds`, which includes
    // `.intrinsicContentSize`) makes AppKit auto-resize the window to fit
    // the hosted SwiftUI content's ideal/intrinsic size on every content
    // change -- and `GogglesConnectionView`'s content uses
    // `.frame(maxWidth: .infinity, maxHeight: .infinity)` throughout (by
    // design, so it fills whatever window size the user picks), which
    // reports a huge ideal height. That combination is what made the
    // window visibly grow taller each time the content changed (device
    // card appearing, `.live`'s video view mounting) instead of staying at
    // the size set below. Disabling `sizingOptions` here keeps the window
    // exactly at the size this code sets (and whatever the user drags it
    // to via `.resizable`), matching the intent of every other explicit
    // `setContentSize` call in this file.
    //
    // This task's aspect-ratio/fullscreen additions below coexist with
    // that fix rather than fighting it: `sizingOptions = []` only stops
    // AppKit from auto-resizing the window to chase SwiftUI's *ideal*
    // content size; `window.contentAspectRatio` (set below) is a completely
    // separate AppKit mechanism that only constrains *user-initiated*
    // resize drags to a fixed ratio, and fullscreen (`.fullScreenPrimary`)
    // is a third, independent mechanism (a window-collection-behavior flag
    // enabling the standard green-button/Control+Cmd+F fullscreen
    // transition). None of the three fight each other: `sizingOptions`
    // governs "does content size drive window size" (no), the aspect
    // ratio governs "what shapes can the user drag the window into" (16:9
    // only), and `.fullScreenPrimary` is orthogonal to both.
    hostingController.sizingOptions = []
    let window = NSWindow(contentViewController: hostingController)
    window.title = "GogglesView"
    // User feedback ("still too small"): 640x360 cramped every state's
    // content (the waitingForKeyframe card's own text was clipped at the
    // window's bottom edge). 960x540 is still exactly 16:9 (contentAspectRatio
    // below still governs user resizing), just 1.5x the linear size --
    // window remains freely resizable, this only changes the launch default.
    let defaultContentSize = NSSize(width: 960, height: 540) // exactly 16:9

    window.setContentSize(defaultContentSize)
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    // task-gui-v2: custom in-app title bar (see the function's own doc
    // comment) -- replaces the native gray gradient titlebar with the app's
    // own dark chrome while keeping the real traffic-light buttons. Applied
    // to `styleMask` before the aspect-ratio/fullscreen setup just below so
    // there's no ordering dependency between the two (verified: `.titled`
    // stays set the whole time, `.fullSizeContentView` just changes how its
    // titlebar draws, and `contentAspectRatio`/`.fullScreenPrimary` are
    // independent AppKit mechanisms per the doc comment on
    // `sizingOptions = []` a few lines below).
    applyCustomTitleBarChrome(to: window)
    // Task 3.6: preserve the video's 16:9 (1920x1080) aspect ratio when the
    // user resizes the window by dragging. `contentAspectRatio` takes a
    // ratio in the content view's own coordinate space (not literal
    // 1920x1080 pixels -- any 16:9-ratio `NSSize` works identically), so a
    // small, exact 16:9 pair is used rather than the full frame resolution.
    window.contentAspectRatio = NSSize(width: 16, height: 9)
    // Task 3.6: standard macOS fullscreen (green button / Control+Cmd+F).
    // `.fullScreenPrimary` is the idiomatic AppKit collection-behavior flag
    // for "this window is a first-class fullscreen destination" -- the
    // window-based equivalent of SwiftUI's `.toggleFullScreen` (which only
    // exists as a `Scene`-level command for the SwiftUI `App` lifecycle
    // this app deliberately isn't using -- see `MenuBarController.swift`'s
    // doc comment for why). No extra plumbing needed beyond this one flag;
    // AppKit supplies the actual fullscreen transition, title-bar button,
    // and menu/keyboard shortcut for free once it's set.
    window.collectionBehavior.insert(.fullScreenPrimary)
    cursorAutoHider = CursorAutoHider(window: window)
    window.center()
    // Task 3.6: closing the window (red titlebar button) hides it instead
    // of destroying it -- the real "show/hide window" affordance this
    // task's menu bar item exposes, and the reason this app is no longer a
    // last-window-closed-quits app (see `RealAppDelegate` below). Actually
    // quitting only ever happens via the menu bar's "Quit" (or the real
    // app-menu's Cmd+Q, standard on `.regular`-activation-policy apps).
    let hideOnCloseDelegate = HideOnCloseWindowDelegate()
    window.delegate = hideOnCloseDelegate
    window.makeKeyAndOrderFront(nil)

    // User feedback (round 3): the previous fixed-constant pill/traffic-
    // light alignment did not actually match on screen; a first attempt at
    // a real measurement, taken right after `applyCustomTitleBarChrome`
    // but BEFORE the window was ever ordered on screen, was closer but
    // still visibly off -- the title bar's internal layout evidently isn't
    // fully settled until the window is actually displayed. Measuring here
    // instead, right after `makeKeyAndOrderFront`, and re-assigning
    // `rootView` with the result (a `NSHostingController`'s `rootView` can
    // be reassigned after creation, so this doesn't require restructuring
    // anything above).
    hostingController.rootView = GogglesConnectionView(
        coordinator: coordinator,
        session: session,
        onOpenSettings: { settingsWindowController.show() },
        onBack: onBack,
        pillBandHeight: AppChrome.measuredPillBandHeight(for: window)
    )

    // Task 3.6: the real menu bar presence -- state glyph, "Reconnect"
    // (relocated here, its proper home, from the temporary "Goggles" main-
    // menu item Task 3.5 added), show/hide window, "Quit". See
    // `MenuBarController.swift` for the `NSStatusItem`-vs-`MenuBarExtra`
    // decision and full behavior.
    let menuBarController = MenuBarController(coordinator: coordinator, window: window)

    // task-gui-v3 point 2's `NSApplication.shared.mainMenu` (App/File/Window,
    // with Settings/Reconnect) is now built ONCE at app launch (see the
    // caller, before the picker is even shown) -- not rebuilt here. This
    // function only needed to enable the Reconnect menu item and set
    // `activeCoordinator`, both of which the caller does right after this
    // function returns `coordinator`.

    // `applicationShouldTerminateAfterLastWindowClosed` is `false` here
    // (unlike `LiveViewAppDelegate`, used by the `--live-view`/
    // `--force-state` dev harnesses, where closing the one window IS "done,
    // exit"): this is the real app shell now, and closing/hiding the main
    // window (via the titlebar button, or the menu bar's show/hide item)
    // must not quit a daily-driver menu-bar app out from under the user.
    let delegate = RealAppDelegate()
    app.delegate = delegate
    GlobalHotkeys.shared.apply()

    // The client is already connected by this point -- reaching
    // `launchMainWindow` required a successful `enumerateDevices` round
    // trip (`DevicePickerCoordinator.poll`) over the same `client`, which
    // only ever happens after `onConnectionStateChange` observed
    // `.connected`. `coordinator`'s own `init` already rewired that
    // closure for its own purposes (see `wireCallbacks`), so unlike the
    // pre-multi-device code this doesn't need a delayed retry -- kick
    // `startStreaming(deviceId:)` immediately.
    client.startStreaming(deviceId: deviceId) { ok, error in
        print("[run] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
    }

    app.activate(ignoringOtherApps: true)
    // Keep strong references to objects nothing else in this process owns,
    // for the remainder of the (already-running, caller-owned) run loop --
    // mirrors why `delegate`/`hideOnCloseDelegate` are `let`-bound above,
    // not inlined. `settingsWindowController` is technically also kept
    // alive already (the `onOpenSettings` closure captured by the
    // still-live `hostingController` holds a strong reference to it), but
    // listed explicitly here too for the same "don't rely on an indirect
    // capture chain to keep this alive" clarity the other two get.
    // `settingsWindowController`/the main-menu's `MenuActionTarget`s are now
    // retained by the caller's `withExtendedLifetime` tuple (built once at
    // app launch, alongside them) instead of here. Unlike Task 3.6's
    // original code, this function can't use
    // `withExtendedLifetime(...) { app.run() }` any more -- the caller's
    // `app.run()` is already in progress by the time this function runs --
    // so `menuBarController`/`hideOnCloseDelegate`/`delegate` (all still
    // genuinely first-constructed here, per device selection) are retained
    // in a top-level array instead (see `mainWindowRetainedObjects`'s doc
    // comment).
    mainWindowRetainedObjects = [menuBarController, hideOnCloseDelegate, delegate]
    mainWindowTeardown = {
        client.stopStreaming(deviceId: deviceId)
        captureWindowController.hide()
        settingsWindowController.setCaptureWindowHandler { _, _ in }
        settingsWindowController.setReconnectHandler {}
        menuBarController.tearDown()
        window.delegate = nil
        window.close()
        mainWindowRetainedObjects = []
    }
    return coordinator
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
    // `--force-state` never opens a real XPC connection (`client.connect()`
    // is deliberately never called below), so no real `deviceId` is ever
    // resolved -- this placeholder is never sent over the wire.
    let coordinator = GogglesConnectionCoordinator(client: client, deviceId: "force-state-placeholder", startWatchdog: false)
    let session = DecodeSession()
    // Sample device info so the card has something to show for every
    // state that displays it (`.claiming` onward) -- a real connection
    // would populate this via `deviceChanged`, which never fires here
    // since `client.connect()` is deliberately never called.
    coordinator.forceState(forced)

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let hostingController = NSHostingController(rootView: GogglesConnectionView(coordinator: coordinator, session: session))
    // See the matching `sizingOptions = []` comment in `--run` above --
    // same view type, same auto-grow behavior otherwise.
    hostingController.sizingOptions = []
    let window = NSWindow(contentViewController: hostingController)
    window.title = "GogglesView -- --force-state \(name) (Task 3.4 manual verification)"
    window.setContentSize(NSSize(width: 480, height: 360))
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    // task-gui-v2: same custom title bar as the real `--run` window, so
    // `--force-state` spot-checks (this task's own visual verification path
    // -- no hardware needed) actually show the real chrome, not the old
    // native titlebar.
    applyCustomTitleBarChrome(to: window)
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
        // Multi-device picker design item 5: `startStreaming` now needs a
        // `deviceId` -- poll for the first available candidate, same as
        // `--live-view` (this harness predates and isn't the real picker
        // UX, design item 7's picker only lives in the `--run` path).
        pollFirstAvailableDeviceId(client: client) { deviceId in
            guard let deviceId else {
                print("[test-client] no device found after polling; giving up on startStreaming")
                finished = true
                return
            }
            client.startStreaming(deviceId: deviceId) { ok, error in
                print("[test-client] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                client.stopStreaming(deviceId: deviceId) {
                    print("[test-client] stopStreaming complete")
                    client.disconnect()
                    finished = true
                }
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

// Reached only for an unrecognized `--something` flag -- a plain launch
// with no arguments (the normal case for a double-clicked .app bundle) no
// longer reaches here as of Task 3.6: it now falls into the same real-app
// path `--run` uses (see that `if` above), which is v1's actual default
// launch behavior, not something gated behind a flag.
print("GogglesView: unrecognized argument(s): \(args.dropFirst().joined(separator: " "))")
print("Recognized dev/debug flags (a plain launch with no flags runs the real app, same as --run):")
print("  --check-daemon-status   print SMAppService.daemon status and exit")
print("  --register              register() the helper daemon as a Login Item")
print("  --unregister            unregister() the helper daemon")
print("  --test-client [secs]    connect via HelperClient, startStreaming, log fps, exit (default 10s)")
print("  --live-view             open a minimal AVSampleBufferDisplayLayer window and stream decoded video")
print("  --force-state <name>    open GogglesConnectionView with uiState forced to <name> (Task 3.4 manual verification)")
print("  --run                   real end-to-end app: connect, startStreaming, menu bar item, aspect-ratio+fullscreen window")
exit(1)

#if canImport(AppKit)
/// Terminates `--live-view`'s `NSApplication.run()` loop when its one
/// window is closed, so the harness process exits instead of hanging as a
/// windowless background app.
final class LiveViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Task 3.6: the real app shell's delegate -- unlike `LiveViewAppDelegate`
/// (used by the `--live-view`/`--force-state` dev harnesses, where the one
/// window closing means the harness is done and should exit), this is a
/// persistent, menu-bar-resident app: closing or hiding the main window must
/// never quit it out from under the user. Quitting only happens via the
/// menu bar's "Quit" item or the standard app-menu Cmd+Q.
final class RealAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Task 3.6: makes the main window's titlebar close button hide the window
/// (`orderOut(nil)`) instead of destroying it -- the "show/hide window"
/// affordance the menu bar's toggle item also exposes, via the same
/// underlying window. `windowShouldClose` returning `false` cancels the
/// real close/destroy; this delegate does the hide itself instead.
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
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

/// task-gui-v2 point 4: replaces the native macOS gray-gradient title bar
/// with the app's own dark chrome, while keeping the real, standard
/// traffic-light window buttons (close/miniaturize/zoom) -- they're just
/// drawn over the app's own content now instead of a separate system bar.
///
/// The three AppKit knobs the brief calls out, and why each one alone isn't
/// the whole story:
///   - `.fullSizeContentView` (added to `styleMask`) extends the content
///     view up underneath where the titlebar used to be, so
///     `GogglesConnectionView`'s own `AppChrome.backgroundColor` fill (and
///     `statusRow`) reaches all the way to the window's top edge.
///   - `titlebarAppearsTransparent = true` makes the (now zero-height,
///     visually) titlebar area not paint the system gray gradient over that
///     extended content.
///   - `titleVisibility = .hidden` hides the window title text that would
///     otherwise still render centered in that transparent strip.
/// None of these three remove `.titled` from `styleMask` -- the traffic
/// lights are a `.titled`-window feature, not a separate opt-in, so they
/// stay exactly where the user expects them (top-left) with zero extra
/// code, just now sitting directly on the dark content instead of a gray
/// bar.
///
/// Two more things this needs to actually read as "one consistent dark
/// surface" rather than "dark content with a flash of the wrong color
/// behind the buttons":
///   - `window.backgroundColor = AppChrome.windowBackgroundColor` -- without
///     this, `NSWindow`'s own default (light) background shows through
///     during the transparent-titlebar region's very first paint, before
///     the hosted SwiftUI view's background has drawn over it, and can
///     briefly show at the window's edges during a live-resize drag.
///   - `isMovableByWindowBackground = true` -- with the titlebar gone as a
///     distinct draggable strip, this is what lets the user still drag the
///     window by clicking any part of its background that isn't itself an
///     interactive SwiftUI control (the status pill/footer button areas
///     still get first claim on their own clicks; everything else in
///     `AppChrome.backgroundColor`'s fill becomes a drag handle, matching
///     how every other borderless-chrome Mac app -- Xcode's floating
///     panels, Slack, etc. -- handles this).
///
/// Does not touch `contentAspectRatio`/`.fullScreenPrimary`/
/// `hostingController.sizingOptions` -- verified independent of all three
/// (see the call site's doc comment in both `--run` and `--force-state`):
/// `.fullSizeContentView` only changes how the *existing* titlebar draws,
/// it doesn't add or remove `.resizable`/`.miniaturizable`, so
/// user-initiated resize drags are still exactly as aspect-ratio-constrained
/// as before, and the green-button/Control+Cmd+F fullscreen transition
/// (`.fullScreenPrimary`) still works unmodified -- AppKit fullscreen
/// already expects (and handles) a full-size-content-view window, that's
/// the same configuration `.fullSizeContentView` document apps have used
/// for fullscreen for years.
#if canImport(AppKit)
func applyCustomTitleBarChrome(to window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = AppChrome.windowBackgroundColor
    window.isMovableByWindowBackground = true
}
#endif

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
