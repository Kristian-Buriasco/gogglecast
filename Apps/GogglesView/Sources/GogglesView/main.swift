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

/// Bridges `DevicePickerCoordinator.$state` to a plain closure fired exactly
/// once, the first time `state` becomes `.selected`, with the candidate's
/// info from the preceding `.picking` list (for the window title).
final class PickerSelectionObserver {
    private var cancellable: AnyObject?

    init(picker: DevicePickerCoordinator, onSelected: @escaping (String, DevicePickerCandidate?) -> Void) {
        var fired = false
        var lastCandidates: [DevicePickerCandidate] = []
        let sink = picker.$state.sink { state in
            if case .picking(let candidates) = state { lastCandidates = candidates }
            guard !fired, case .selected(let deviceId) = state else { return }
            fired = true
            onSelected(deviceId, lastCandidates.first { $0.id == deviceId })
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
    // Task 3.6: this is v1's real default launch behavior -- a plain
    // double-click of the app bundle (no arguments) lands here, same as the
    // explicit `--run` synonym.
    //
    // Roadmap Phase 2 (multi-goggles in separate windows): every connected
    // goggles the user picks gets its own `GogglesSession` -- an
    // independently sized/positioned window streaming simultaneously -- all
    // sharing this one `HelperClient` (the helper fans out per deviceId; the
    // client routes callbacks per deviceId). `SessionRegistry` keeps one
    // session per device; picking an already-open device focuses its window.
    //
    // Window behavior:
    //   - The picker is a single reusable window, reachable from Goggles >
    //     Open Another Goggles… (⌘N), the menu-bar item, and each goggles
    //     window's "Devices" button. Picking a device opens its window and
    //     leaves every other window streaming.
    //   - A goggles window's red close button hides it (streaming continues,
    //     as before multi-window); "Disconnect" (footer button, Goggles menu,
    //     or the menu-bar item's per-device submenu) stops that device and
    //     closes only its window. Disconnecting the last one re-opens the
    //     picker so the app never sits with no window at all.
    //   - App-level commands (File > Reconnect, Settings' Reconnect, Goggles >
    //     Disconnect, global hotkeys) act on the key goggles window, else
    //     the most recently focused one.
    print("GogglesView: connecting to \(helperMachServiceName) and opening the real connection view...")

    let client = HelperClient()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // Built once, before the picker: registering the helper is exactly what a
    // user needs to do before any device can show up.
    let settingsWindowController = SettingsWindowController()
    let registry = SessionRegistry<GogglesSession>()

    /// The session an app-level command should act on.
    func sessionForCommand() -> GogglesSession? {
        registry.all.first { $0.owns(NSApp.keyWindow) } ?? registry.activeSession
    }

    GlobalHotkeyRouting.targetProvider = { sessionForCommand()?.decodeSession }

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
    fileMenu.autoenablesItems = false
    let settingsMenuTarget = MenuActionTarget { settingsWindowController.show() }
    let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(MenuActionTarget.invoke), keyEquivalent: ",")
    settingsMenuItem.target = settingsMenuTarget
    fileMenu.addItem(settingsMenuItem)
    let reconnectMenuTarget = MenuActionTarget { sessionForCommand()?.coordinator.reconnect() }
    let reconnectMenuItem = NSMenuItem(title: "Reconnect", action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
    reconnectMenuItem.target = reconnectMenuTarget
    reconnectMenuItem.isEnabled = false
    fileMenu.addItem(reconnectMenuItem)
    fileMenuItem.submenu = fileMenu

    // Forward-declared so the menu targets below can call them.
    var presentPicker: () -> Void = {}
    var disconnectSession: (String) -> Void = { _ in }

    let gogglesMenuItem = NSMenuItem()
    mainMenu.addItem(gogglesMenuItem)
    let gogglesMenu = NSMenu(title: "Goggles")
    gogglesMenu.autoenablesItems = false
    let openAnotherMenuTarget = MenuActionTarget { presentPicker() }
    let openAnotherMenuItem = NSMenuItem(title: "Open Another Goggles…", action: #selector(MenuActionTarget.invoke), keyEquivalent: "n")
    openAnotherMenuItem.target = openAnotherMenuTarget
    gogglesMenu.addItem(openAnotherMenuItem)
    let disconnectMenuTarget = MenuActionTarget {
        if let session = sessionForCommand() { disconnectSession(session.deviceId) }
    }
    let disconnectMenuItem = NSMenuItem(title: "Disconnect", action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
    disconnectMenuItem.target = disconnectMenuTarget
    disconnectMenuItem.isEnabled = false
    gogglesMenu.addItem(disconnectMenuItem)
    gogglesMenuItem.submenu = gogglesMenu

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

    // Capture-window prefs apply to every open goggles window (each has its
    // own, per-device-titled capture window); new windows apply them on open.
    settingsWindowController.setCaptureWindowHandler { enabled, onTop in
        registry.all.forEach { $0.applyCaptureWindowPrefs(enabled: enabled, onTop: onTop) }
    }

    registry.addObserver {
        let hasSessions = !registry.isEmpty
        reconnectMenuItem.isEnabled = hasSessions
        disconnectMenuItem.isEnabled = hasSessions
        settingsWindowController.setReconnectHandler(hasSessions ? { sessionForCommand()?.coordinator.reconnect() } : nil)
        if let active = registry.activeSession {
            MiniWindowController.shared.sync(session: active.decodeSession)
        }
    }

    let appDelegate = MultiWindowAppDelegate(
        shouldTerminateAfterLastWindowClosed: { registry.isEmpty },
        onReopen: {
            if let session = registry.activeSession { session.focus() } else { presentPicker() }
        }
    )
    app.delegate = appDelegate

    var pickerWindow: NSWindow?
    var pickerRetained: [Any] = []
    var didRunFirstSessionSetup = false

    func dismissPicker() {
        let window = pickerWindow
        let retained = pickerRetained
        pickerWindow = nil
        pickerRetained = []
        window?.close()
        // Called from inside the selection observer's own sink: release the
        // picker objects on the next turn, not mid-callback.
        DispatchQueue.main.async { withExtendedLifetime(retained) {} }
    }

    func openSession(deviceId: String, info: DevicePickerCandidate?) {
        let cascadeFrom = registry.activeSession?.window
        let (session, created) = registry.openOrFocus(deviceId: deviceId) {
            launchMainWindow(
                deviceId: deviceId, initialInfo: info, client: client,
                cascadeFrom: cascadeFrom,
                settingsWindowController: settingsWindowController,
                onOpenAnother: { presentPicker() },
                onDisconnect: { disconnectSession($0) }
            )
        }
        guard created else { return }
        session.onBecameKey = { registry.markActive($0.deviceId) }
        let defaults = UserDefaults.standard
        session.applyCaptureWindowPrefs(
            enabled: defaults.bool(forKey: CaptureWindowPrefs.enabledKey),
            onTop: defaults.bool(forKey: CaptureWindowPrefs.onTopKey)
        )
        if !didRunFirstSessionSetup {
            didRunFirstSessionSetup = true
            UpdateChecker.shared.checkOnLaunchIfDue()
        }
        app.activate(ignoringOtherApps: true)
    }

    presentPicker = {
        if let existing = pickerWindow {
            existing.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            return
        }
        let picker = DevicePickerCoordinator(client: client)
        let pickerHostingController = NSHostingController(rootView: DevicePickerView(
            picker: picker,
            onOpenSettings: { settingsWindowController.show() }
        ))
        pickerHostingController.sizingOptions = []
        let window = NSWindow(contentViewController: pickerHostingController)
        window.title = "GogglesView"
        window.setContentSize(NSSize(width: 720, height: 520))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        applyCustomTitleBarChrome(to: window)
        window.center()
        if let active = registry.activeSession?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: active.frame.minX, y: active.frame.maxY)))
        }
        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // Picker closed (by the user, or after a selection): drop it and
            // its polling for good.
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            if pickerWindow === window { pickerWindow = nil; pickerRetained = [] }
        }
        let selection = PickerSelectionObserver(picker: picker) { deviceId, info in
            // Open (or focus) the goggles window BEFORE closing the picker so
            // the app never passes through a zero-window state.
            openSession(deviceId: deviceId, info: info)
            dismissPicker()
        }
        pickerWindow = window
        pickerRetained = [selection, pickerHostingController, picker]
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        picker.resumeIfConnected()
    }

    disconnectSession = { deviceId in
        guard registry.session(for: deviceId) != nil else { return }
        // Last window: bring the picker up first (never zero windows, and
        // `shouldTerminateAfterLastWindowClosed` must not see an empty app).
        if registry.count == 1 { presentPicker() }
        guard let session = registry.remove(deviceId: deviceId) else { return }
        // Next turn: this often runs from a SwiftUI button inside the very
        // hosting view `teardown()` removes.
        DispatchQueue.main.async { session.teardown() }
    }

    let menuBarController = MenuBarController(
        registry: registry,
        onOpenAnother: { presentPicker() },
        onDisconnect: { disconnectSession($0) }
    )

    GlobalHotkeys.shared.apply()
    presentPicker()
    OnboardingWindow.showIfFirstRun()  // after the picker so it opens on top

    client.connect()
    app.activate(ignoringOtherApps: true)
    // `app.run()` is called exactly once for the whole process; every window
    // after this point is created from main-queue callbacks while it spins.
    withExtendedLifetime((appDelegate, settingsWindowController, settingsMenuTarget, reconnectMenuTarget,
                         openAnotherMenuTarget, disconnectMenuTarget, menuBarController, registry)) {
        app.run()
    }
    exit(0)
}

/// Thin factory for one goggles window: builds a `GogglesSession` (coordinator,
/// decode session, window, capture window, hook wiring) and starts streaming.
/// The caller registers it in the `SessionRegistry`.
func launchMainWindow(
    deviceId: String, initialInfo: DevicePickerCandidate?, client: HelperClient,
    cascadeFrom: NSWindow?,
    settingsWindowController: SettingsWindowController,
    onOpenAnother: @escaping () -> Void,
    onDisconnect: @escaping (String) -> Void
) -> GogglesSession {
    let session = GogglesSession(
        deviceId: deviceId,
        initialInfo: initialInfo,
        client: client,
        cascadeFrom: cascadeFrom,
        onOpenSettings: { settingsWindowController.show() },
        onOpenAnother: onOpenAnother,
        onDisconnect: onDisconnect
    )
    session.start()
    return session
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

/// The real app shell's delegate. Before any goggles window exists, closing
/// the picker quits (nothing else to show); once one does, the app is a
/// persistent menu-bar-resident app and closing/hiding windows never quits
/// it -- only the menu's Quit / Cmd+Q does. A Dock click with nothing visible
/// brings back the active goggles window (or the picker).
final class MultiWindowAppDelegate: NSObject, NSApplicationDelegate {
    private let shouldTerminate: () -> Bool
    private let onReopen: () -> Void

    init(shouldTerminateAfterLastWindowClosed: @escaping () -> Bool, onReopen: @escaping () -> Void) {
        self.shouldTerminate = shouldTerminateAfterLastWindowClosed
        self.onReopen = onReopen
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { shouldTerminate() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { onReopen() }
        return true
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
