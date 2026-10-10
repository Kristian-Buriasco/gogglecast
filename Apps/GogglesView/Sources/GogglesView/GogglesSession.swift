import Foundation
import GogglesXPC
#if canImport(AppKit)
import AppKit
import SwiftUI
import Combine
#endif

extension Notification.Name {
    /// Posted (object: the session's `DecodeSession`) right before a goggles
    /// window is torn down, so per-window views can finalize recordings.
    static let gogglesSessionWillClose = Notification.Name("GogglesSessionWillClose")
    /// Posted (object: deviceId) when the user chose "Stop and disconnect" while closing a window that is recording or streaming.
    static let gogglesStopAndDisconnect = Notification.Name("GogglesStopAndDisconnect")
}

/// Pure naming helpers for per-device windows (unit-tested).
enum GogglesSessionNaming {
    /// "DJI Goggles 3 (…1234)" -- serial suffix, or the deviceId when there's no serial.
    static func deviceLabel(product: String?, serial: String?, deviceId: String) -> String {
        let name = (product?.isEmpty == false ? product! : L("Goggles"))
        if let serial, !serial.isEmpty {
            return "\(name) (…\(serial.suffix(4)))"
        }
        return "\(name) (\(deviceId))"
    }

    static func mainWindowTitle(label: String) -> String { "GogglesView — \(label)" }
    /// OBS Window Capture lists windows by title, so each device needs its own.
    static func captureWindowTitle(label: String) -> String { "GogglesView Capture — \(label)" }
    /// `WindowMemory` autosave name: per device so each window keeps its own frame.
    static func windowMemoryName(deviceId: String) -> String { "main.\(deviceId)" }
}

#if canImport(AppKit)

/// Everything one open goggles window owns: its connection coordinator,
/// decode session, main window, OBS capture window and hook wiring.
/// Created by `launchMainWindow` (main.swift) and registered in the app's
/// `SessionRegistry` so a device is never opened twice.
///
/// Close semantics: the red close button only hides the window (streaming,
/// recording, replay buffer and capture/mini windows keep running) -- the
/// pre-multi-window behavior, now per window; hidden windows come back from
/// the menu-bar item. `teardown()` (the window's "Disconnect" button or
/// Goggles > Disconnect) is what stops the device's stream.
final class GogglesSession: NSObject, RegistrableSession, NSWindowDelegate {
    let deviceId: String
    let coordinator: GogglesConnectionCoordinator
    let decodeSession: DecodeSession
    let window: NSWindow
    let captureWindowController: CaptureWindowController

    private let client: HelperClient
    private let hostingController: NSHostingController<GogglesConnectionView>
    private var cursorAutoHider: CursorAutoHider?
    private var cancellables = Set<AnyCancellable>()
    private var initialInfo: DevicePickerCandidate?
    private(set) var isTornDown = false
    private var signalAlert: SignalAlertController?
    private var autoMarkers: AutoMarkerController?

    /// Fired when this session's window becomes key (registry -> active session).
    var onBecameKey: ((GogglesSession) -> Void)?

    private(set) var label: String

    init(
        deviceId: String,
        initialInfo: DevicePickerCandidate?,
        client: HelperClient,
        cascadeFrom: NSWindow?,
        onOpenSettings: @escaping () -> Void,
        onOpenAnother: @escaping () -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {
        self.deviceId = deviceId
        self.client = client
        self.initialInfo = initialInfo
        self.label = GogglesSessionNaming.deviceLabel(product: initialInfo?.product, serial: initialInfo?.serial, deviceId: deviceId)

        let coordinator = GogglesConnectionCoordinator(client: client, deviceId: deviceId)
        let decodeSession = DecodeSession()
        decodeSession.onDroppedSample = { error in
            print("[run \(deviceId)] dropped sample: \(error)")
        }
        decodeSession.onTeardown = {
            print("[run \(deviceId)] decode session torn down after \(DecodeSession.maxConsecutiveFailures) consecutive failures -- waiting for next parameter set")
        }
        coordinator.onNALUnit = { [weak decodeSession] data, nalType, isParameterSet, hostTime in
            decodeSession?.handle(nalData: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
        }
        coordinator.onInputDropped = { [weak decodeSession] in decodeSession?.noteInputDropped() }
        self.coordinator = coordinator
        self.decodeSession = decodeSession
        FeedSlots.shared.assign(deviceId: deviceId, decode: decodeSession)

        let capture = CaptureWindowController(session: decodeSession)
        capture.title = GogglesSessionNaming.captureWindowTitle(label: label)
        self.captureWindowController = capture

        let makeView: (CGFloat) -> GogglesConnectionView = { pill in
            GogglesConnectionView(
                coordinator: coordinator,
                session: decodeSession,
                onOpenSettings: onOpenSettings,
                onOpenAnother: onOpenAnother,
                onDisconnect: { onDisconnect(deviceId) },
                pillBandHeight: pill
            )
        }
        let hostingController = NSHostingController(rootView: makeView(AppChrome.titleBarHeight))
        // See the long `sizingOptions = []` rationale in main.swift's history:
        // content-size-driven window growth fights the 16:9 window.
        hostingController.sizingOptions = []
        self.hostingController = hostingController

        let window = NSWindow(contentViewController: hostingController)
        window.title = GogglesSessionNaming.mainWindowTitle(label: label)
        window.setContentSize(NSSize(width: 960, height: 540))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        applyCustomTitleBarChrome(to: window)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        self.window = window

        super.init()

        let memoryName = GogglesSessionNaming.windowMemoryName(deviceId: deviceId)
        let hadSavedFrame = WindowMemory.hasSavedFrame(name: memoryName)
        if !hadSavedFrame, cascadeFrom == nil {
            // First window for this device and no other goggles open: inherit
            // the pre-multi-window single-window frame.
            WindowMemory.copySavedFrame(from: "main", to: memoryName)
        }
        window.center()
        WindowMemory.attach(to: window, name: memoryName, restoreSize: true, contentAspect: 16.0 / 9.0)
        if !hadSavedFrame, let cascadeFrom {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: cascadeFrom.frame.minX, y: cascadeFrom.frame.maxY)))
        }
        window.delegate = self
        cursorAutoHider = CursorAutoHider(window: window)

        EventHookInstaller.install(coordinator: coordinator)
        signalAlert = SignalAlertController(coordinator: coordinator, deviceLabel: { [weak self] in
            guard let self else { return L("Goggles") }
            return ProgramFeedNaming.displayName(deviceId: self.deviceId, fallback: self.window.title)
        })
        SessionLogger.attach(coordinator: coordinator, decodeSession: decodeSession).store(in: &cancellables)
        autoMarkers = AutoMarkerController(
            deviceId: deviceId, session: decodeSession,
            isRecording: { [weak decodeSession] in
                guard let decodeSession else { return false }
                return SessionControlBoard.shared.recorder(for: decodeSession)?.isRecording == true
            },
            addMarker: { [weak decodeSession] label in
                guard let decodeSession else { return }
                SessionControlBoard.shared.recorder(for: decodeSession)?.addMarker(label: label, auto: true)
            })
        // A decoder without a keyframe shows the "waiting for the first picture" card even when the
        // helper says live, and makes the coordinator ask for a keyframe (then reconnect).
        decodeSession.$isWaitingForKeyframe
            .sink { [weak coordinator] waiting in coordinator?.setDecoderWaitingForKeyframe(waiting) }
            .store(in: &cancellables)

        coordinator.$deviceInfo
            .compactMap { $0 }
            .sink { [weak self] info in
                self?.updateLabel(product: info.product, serial: info.serial)
                if ProfileContext.shared.serial == nil || self?.window.isKeyWindow == true { ProfileContext.shared.serial = info.serial }
                ProfileStore.shared.applyIfEnabled(serial: info.serial)
            }
            .store(in: &cancellables)
    }

    /// Shows the window (measuring the real title-bar band once on screen)
    /// and starts this device's stream.
    func start() {
        window.makeKeyAndOrderFront(nil)
        // Measured after ordering on screen: the title bar layout isn't
        // settled before that (see AppChrome.measuredPillBandHeight).
        var view = hostingController.rootView
        view.pillBandHeight = AppChrome.measuredPillBandHeight(for: window)
        hostingController.rootView = view
        client.startStreaming(deviceId: deviceId) { [deviceId] ok, error in
            print("[run \(deviceId)] startStreaming -> ok=\(ok) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }

    /// Mac is going to sleep: mark a running recording and keep the signal alert quiet.
    func powerWillSleep() {
        guard !isTornDown else { return }
        SessionControlBoard.shared.recorder(for: decodeSession)?.addMarker(label: PowerEvents.sleepMarkerLabel)
        signalAlert?.suspendForSleep()
    }

    /// Mac woke up: the link to the goggles is probably stale, so reconnect.
    func powerDidWake() {
        guard !isTornDown else { return }
        coordinator.reconnect()
    }

    func focus() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleVisibility() {
        if window.isVisible { window.orderOut(nil) } else { focus() }
    }

    /// True for this session's main or capture window.
    func owns(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        return candidate === window || candidate === captureWindowController.window
    }

    func applyCaptureWindowPrefs(enabled: Bool, onTop: Bool) {
        captureWindowController.keepOnTop = onTop
        if enabled { captureWindowController.show() } else { captureWindowController.hide() }
    }

    /// Stops this device's stream and closes everything this session opened.
    /// Idempotent. Other sessions are untouched.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        FeedSlots.shared.release(deviceId: deviceId, decode: decodeSession)
        signalAlert?.userDisconnected()
        signalAlert = nil
        autoMarkers = nil
        NotificationCenter.default.post(name: .gogglesSessionWillClose, object: decodeSession)
        client.stopStreaming(deviceId: deviceId)
        coordinator.detach()
        coordinator.onNALUnit = nil
        coordinator.onInputDropped = nil
        EventHookInstaller.uninstall(deviceId: deviceId)
        MiniWindowController.shared.detach(session: decodeSession)
        captureWindowController.hide()
        cancellables.removeAll()
        cursorAutoHider = nil
        window.delegate = nil
        window.orderOut(nil)
        // Drops the SwiftUI tree so per-window consumers (replay buffer,
        // network streamer, data collector) get their onDisappear cleanup.
        window.contentViewController = nil
        window.close()
    }

    private func updateLabel(product: String?, serial: String?) {
        label = GogglesSessionNaming.deviceLabel(product: product, serial: serial, deviceId: deviceId)
        window.title = GogglesSessionNaming.mainWindowTitle(label: label)
        captureWindowController.title = GogglesSessionNaming.captureWindowTitle(label: label)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let board = SessionControlBoard.shared
        let prompt = ConnectionMessages.closePrompt(
            recording: board.recorder(for: decodeSession)?.isRecording == true,
            streaming: board.streamer(for: decodeSession)?.isStreaming == true)
        if let prompt {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: L("Hide window"))
            alert.addButton(withTitle: L("Stop and disconnect"))
            if alert.runModal() == .alertSecondButtonReturn {
                NotificationCenter.default.post(name: .gogglesStopAndDisconnect, object: deviceId)
                return false
            }
        }
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let serial = coordinator.deviceInfo?.serial { ProfileContext.shared.serial = serial }
        onBecameKey?(self)
    }
}
#endif
