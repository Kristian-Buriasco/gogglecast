#if canImport(AppKit)
import AppKit
import Combine
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 3.6: the real menu bar presence -- state glyph (design plan §3.6:
// "Menu bar extra with state glyph, show/hide window, Reconnect, Quit").
//
// `NSStatusItem` vs SwiftUI's `MenuBarExtra`: the brief explicitly asks to
// verify `MenuBarExtra` covers the needed behavior before committing to it
// over the older API. It does cover dynamic glyph swapping (an `Image` view
// driven by `@State`/`@ObservedObject` re-renders like any other SwiftUI
// view) -- but it only exists as a `Scene` inside a SwiftUI `App`, and this
// app is not, and after this task still isn't, structured as one: every
// window in this file is built and owned imperatively
// (`NSApplication.shared`, raw `NSWindow`/`NSHostingController`
// construction in `main.swift`), because `main.swift`'s top-level code IS
// the program's entry point -- Swift does not allow a `@main` type in the
// same target as a file with top-level statements, so adopting
// `MenuBarExtra` would mean restructuring the entire app onto the SwiftUI
// `App`/`Scene` lifecycle just to gain a status item. That's disproportionate
// to this task and risks re-touching the exact window plumbing (manual
// `NSWindow` sizing, `NSHostingController.sizingOptions`) that Task 3.5's
// hotfix just got working against real hardware. `NSStatusItem` slots
// directly into the existing imperative AppKit code with zero lifecycle
// change, and its API (a swappable `button.image`, a real `NSMenu`) covers
// every behavior this task needs.
// ─────────────────────────────────────────────────────────────────────────

/// Owns the app's single `NSStatusItem`. Multi-window: the glyph summarizes
/// every open goggles window (`summaryCategory`, plus a red dot while any
/// window records), and the menu lists each session with its mini-controls
/// (`MenuBarMiniControls`: record, replay, screenshot, freeze, marker,
/// show/hide, network stream) plus Reconnect and Disconnect, then
/// "Add Goggles…", Settings… and Quit. Created once at launch and
/// kept alive for the app's lifetime (`NSStatusItem` does not keep itself
/// alive). Hidden (not removed) while "Show menu bar item" is off.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let registry: SessionRegistry<GogglesSession>
    private let onOpenAnother: () -> Void
    private let onOpenSettings: (() -> Void)?
    private let onDisconnect: (String) -> Void

    /// `NSMenuItem.target` is weak, so the menu's closure targets live here;
    /// rebuilt every time the menu opens.
    private var menuTargets: [MenuActionTarget] = []
    private var stateCancellables: [AnyCancellable] = []
    private var registryObserver: UUID?
    private var notificationObservers: [NSObjectProtocol] = []
    /// Items whose titles tick while the menu is open (fps, recording time).
    private var liveTitles: [(NSMenuItem, () -> String?)] = []
    private var liveTimer: Timer?

    init(registry: SessionRegistry<GogglesSession>, onOpenAnother: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil, onDisconnect: @escaping (String) -> Void) {
        self.registry = registry
        self.onOpenAnother = onOpenAnother
        self.onOpenSettings = onOpenSettings
        self.onDisconnect = onDisconnect
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu(menu)

        registryObserver = registry.addObserver { [weak self] in self?.resubscribe() }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: .gogglesControlBoardChanged, object: nil, queue: .main) { [weak self] _ in
                self?.resubscribe()
            },
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyVisibility()
            },
        ]
        applyVisibility()
        resubscribe()
    }

    /// Removes the status item; the controller is unusable afterwards.
    func tearDown() {
        if let registryObserver { registry.removeObserver(registryObserver) }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers = []
        stopLiveTimer()
        stateCancellables = []
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func applyVisibility() {
        let show = MenuBarPrefs.show()
        if statusItem.isVisible != show { statusItem.isVisible = show }
    }

    private func resubscribe() {
        // `@Published` fires before the stored value changes; read the new
        // values on the next turn.
        let refresh: (Any) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.updateGlyph() } }
        stateCancellables = registry.all.map { $0.coordinator.$uiState.sink(receiveValue: refresh) }
        stateCancellables += registry.all.compactMap {
            SessionControlBoard.shared.recorder(for: $0.decodeSession)?.$isRecording.sink(receiveValue: refresh)
        }
        // Battery and picture warnings from the event status also colour the icon.
        stateCancellables.append(NotificationCenter.default.publisher(for: .eventStatusChanged).sink(receiveValue: refresh))
        updateGlyph()
    }

    // MARK: - Snapshot / actions

    private func snapshot(for session: GogglesSession) -> MiniControlsSnapshot {
        let coordinator = session.coordinator
        let board = SessionControlBoard.shared
        let recorder = board.recorder(for: session.decodeSession)
        let streamer = board.streamer(for: session.decodeSession)
        var isLive = false
        if case .live = coordinator.uiState { isLive = true }
        return MiniControlsSnapshot(
            label: session.label,
            statusText: MenuBarController.displayText(for: coordinator.uiState),
            isLive: isLive,
            fps: coordinator.stats?.fps,
            batteryPercent: coordinator.batteryPercent,
            isRecording: recorder?.isRecording ?? false,
            recordingElapsed: recorder?.elapsed ?? 0,
            isFrozen: session.decodeSession.freezeState.isFrozen,
            isNetworkStreaming: streamer?.isStreaming ?? false,
            networkStreamAvailable: streamer != nil,
            replayEnabled: UserDefaults.standard.bool(forKey: ReplayPrefs.enabledKey),
            isWindowVisible: session.window.isVisible
        )
    }

    private func perform(_ action: MiniControlAction, on session: GogglesSession) {
        if let hotkey = action.hotkeyAction {
            // Same notification + per-window routing the global hotkeys use.
            NotificationCenter.default.post(name: hotkey.notification, object: session.decodeSession)
            return
        }
        switch action {
        case .toggleFreeze:
            session.decodeSession.freezeState.toggle()
        case .showWindow:
            session.toggleVisibility()
        case .toggleNetworkStream:
            NotificationCenter.default.post(name: .gogglesToggleNetworkStream, object: session.decodeSession)
        case .addMarker:
            SessionControlBoard.shared.recorder(for: session.decodeSession)?.addMarker(label: L("Marker"))
        case .copyFrame:
            NotificationCenter.default.post(name: .gogglesCopyFrame, object: session.decodeSession)
        case .toggleRecording, .saveReplay, .screenshot:
            break
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        rebuildMenu(menu)
        updateGlyph()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu, liveTimer == nil else { return }
        // `.common` so it also fires while the menu is tracking.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.liveTitles.forEach { item, title in
                if let title = title() { item.title = title }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        stopLiveTimer()
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(action)
        menuTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke), keyEquivalent: key)
        item.target = target
        return item
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menuTargets = []
        liveTitles = []
        let sessions = registry.all
        if sessions.isEmpty {
            let none = NSMenuItem(title: L("No goggles open"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for session in sessions {
            let snap = snapshot(for: session)
            let header = NSMenuItem(title: MenuBarMiniControls.headerTitle(snap), action: nil, keyEquivalent: "")
            header.image = MenuBarController.glyphImage(for: session.coordinator.uiState.kind)
            liveTitles.append((header, { [weak self, weak session] in
                guard let self, let session else { return nil }
                return MenuBarMiniControls.headerTitle(self.snapshot(for: session))
            }))
            let sub = NSMenu()
            sub.autoenablesItems = false
            let info = NSMenuItem(title: MenuBarMiniControls.infoLine(snap), action: nil, keyEquivalent: "")
            info.isEnabled = false
            liveTitles.append((info, { [weak self, weak session] in
                guard let self, let session else { return nil }
                return MenuBarMiniControls.infoLine(self.snapshot(for: session))
            }))
            sub.addItem(info)
            sub.addItem(.separator())
            for control in MenuBarMiniControls.items(snap) {
                let action = control.action
                let menuItem = item(control.title) { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.perform(action, on: session)
                }
                menuItem.isEnabled = control.isEnabled
                menuItem.state = control.isOn ? .on : .off
                if action == .addMarker, control.isEnabled {
                    // Same preset labels as the window's marker menu.
                    let labels = NSMenu()
                    for label in RecordingMarkers.defaultLabels {
                        labels.addItem(item(label) { [weak session] in
                            guard let session else { return }
                            SessionControlBoard.shared.recorder(for: session.decodeSession)?.addMarker(label: label)
                        })
                    }
                    menuItem.submenu = labels
                }
                sub.addItem(menuItem)
                if action == .addMarker { sub.addItem(.separator()) }
            }
            let deviceId = session.deviceId
            sub.addItem(.separator())
            sub.addItem(item(L("Reconnect")) { [weak session] in session?.coordinator.reconnect() })
            sub.addItem(item(L("Disconnect")) { [weak self] in self?.onDisconnect(deviceId) })
            header.submenu = sub
            menu.addItem(header)
        }
        menu.addItem(.separator())
        menu.addItem(item(L("Add Goggles…")) { [weak self] in self?.onOpenAnother() })
        menu.addItem(item(L("Setup assistant…")) {
            NSApp.activate(ignoringOtherApps: true)
            OnboardingWindow.show()
        })
        let raceItem = item(L("Race Mode")) { RaceModeController.shared.toggle() }
        raceItem.state = RaceModePrefs.enabled ? .on : .off
        menu.addItem(raceItem)
        if let onOpenSettings {
            menu.addItem(item(L("Settings…")) {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSettings()
            })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit GogglesView"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Glyph

    private func updateGlyph() {
        let sessions = registry.all
        let category = MenuBarController.summaryCategory(sessions.map { $0.coordinator.uiState.kind }, status: EventStatus.shared.worst)
        let recording = MenuBarMiniControls.anyRecording(sessions.map(snapshot(for:)))
        let base = MenuBarController.glyphImage(for: category)
        statusItem.button?.image = recording ? MenuBarController.recordingBadged(base) : base
        var summary = sessions
            .map { "\($0.label): \(MenuBarController.displayText(for: $0.coordinator.uiState))" }
            .joined(separator: "; ")
        let warnings = EventStatus.shared.rows.filter { !$0.issues.isEmpty }
            .map { "\($0.name): \($0.issues.map(\.text).joined(separator: ", "))" }.joined(separator: "; ")
        if !warnings.isEmpty { summary += (summary.isEmpty ? "" : "; ") + warnings }
        if recording { summary = L("%@ (recording)", summary) }
        statusItem.button?.image?.accessibilityDescription = L("GogglesView: %@", summary.isEmpty ? L("no goggles open") : summary)
        statusItem.button?.toolTip = summary.isEmpty ? "GogglesView" : summary
    }

    /// The status glyph with a red recording dot in its top-right corner.
    static func recordingBadged(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let d = max(4, rect.width * 0.42)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Worst-wins summary over every open window: any error -> error, else any
    /// in-progress -> waiting, else live. No windows -> waiting (nothing is
    /// wrong, nothing is live).
    static func summaryCategory(_ kinds: [GogglesUIStateKind]) -> GogglesStatusGlyphCategory {
        let categories = kinds.map(\.statusGlyphCategory)
        if categories.isEmpty { return .waiting }
        if categories.contains(.error) { return .error }
        if categories.contains(.waiting) { return .waiting }
        return .live
    }

    /// The icon colour with the event status folded in: a red feed (a critical battery, say) makes the icon red,
    /// an amber one (low battery, black or frozen picture) makes a healthy icon yellow.
    static func summaryCategory(_ kinds: [GogglesUIStateKind], status: FeedHealth?) -> GogglesStatusGlyphCategory {
        let base = summaryCategory(kinds)
        switch status {
        case .bad: return .error
        case .warning: return base == .live ? .waiting : base
        default: return base
        }
    }

    /// design §6-derived short status text for the disabled top menu line --
    /// intentionally not `String(describing:)`'d off `GogglesUIStateKind`'s
    /// raw case names, which read as code, not UI copy.
    ///
    /// - Parameter stats: user-requested addition -- when live, append the
    ///   current resolution and framerate ("Live · 1920x1080 · 56fps").
    ///   Resolution is the one fixed profile this app decodes (design §1's
    ///   single VID:PID/stream profile), not read per-frame; framerate is
    ///   `stats.fps`, the same real, live-updating value the app's own
    ///   `[client-fps]` log line and `gvcli --stats` report. `stats == nil`
    ///   (not yet received one, or a non-`.live` state) omits the suffix
    ///   entirely rather than showing a stale/zero placeholder.
    static func displayText(for state: GogglesUIState, stats: StreamStats? = nil, resolution: String? = nil) -> String {
        switch state {
        case .live:
            guard let stats else { return L("Live") }
            return [L("Live"), resolution, "\(stats.fps)fps"].compactMap { $0 }.joined(separator: " · ")
        default:
            return ConnectionMessages.shortStatus(for: state)
        }
    }

    /// SF Symbol + tint per `GogglesStatusGlyphCategory` (the pure,
    /// AppKit-free three-bucket mapping in `GogglesUIState.swift`). Not a
    /// template image -- the whole point of the color is to be visible at a
    /// glance in the menu bar, matching the colored-status-dot idea from the
    /// user-supplied CosmoViewer Direct reference (design §6 framing: UX
    /// reference only, not a spec).
    static func glyphImage(for kind: GogglesUIStateKind) -> NSImage? {
        glyphImage(for: kind.statusGlyphCategory)
    }

    static func glyphImage(for category: GogglesStatusGlyphCategory) -> NSImage? {
        let symbolName: String
        let color: NSColor
        switch category {
        case .error:
            symbolName = "exclamationmark.triangle.fill"
            color = .systemRed
        case .waiting:
            symbolName = "arrow.triangle.2.circlepath"
            color = .systemYellow
        case .live:
            symbolName = "eye.fill"
            color = .systemGreen
        }
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = base?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Settings > General toggle for the status item.
struct MenuBarItemSettingsToggle: View {
    @AppStorage(MenuBarPrefs.showKey) private var show = true
    var body: some View {
        Toggle("Show menu bar item", isOn: $show)
            .accessibilityIdentifier("showMenuBarItemToggle")
    }
}
#endif
#endif
