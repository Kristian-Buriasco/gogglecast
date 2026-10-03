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
/// every open goggles window (`summaryCategory`), and the menu lists each
/// session with its own Show/Hide, Reconnect and Disconnect items, plus
/// "Open Another Goggles…". Created once at launch and kept alive for the
/// app's lifetime (`NSStatusItem` does not keep itself alive).
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let registry: SessionRegistry<GogglesSession>
    private let onOpenAnother: () -> Void
    private let onDisconnect: (String) -> Void

    /// `NSMenuItem.target` is weak, so the menu's closure targets live here;
    /// rebuilt every time the menu opens.
    private var menuTargets: [MenuActionTarget] = []
    private var stateCancellables: [AnyCancellable] = []
    private var registryObserver: UUID?

    init(registry: SessionRegistry<GogglesSession>, onOpenAnother: @escaping () -> Void, onDisconnect: @escaping (String) -> Void) {
        self.registry = registry
        self.onOpenAnother = onOpenAnother
        self.onDisconnect = onDisconnect
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)

        registryObserver = registry.addObserver { [weak self] in self?.resubscribe() }
        resubscribe()
    }

    /// Removes the status item; the controller is unusable afterwards.
    func tearDown() {
        if let registryObserver { registry.removeObserver(registryObserver) }
        stateCancellables = []
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func resubscribe() {
        stateCancellables = registry.all.map { session in
            session.coordinator.$uiState.sink { [weak self] _ in
                // `@Published` fires before the stored value changes; read
                // the new values on the next turn.
                DispatchQueue.main.async { self?.updateGlyph() }
            }
        }
        updateGlyph()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
        updateGlyph()
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
        let sessions = registry.all
        if sessions.isEmpty {
            let none = NSMenuItem(title: "No goggles open", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for session in sessions {
            let state = session.coordinator.uiState
            let header = NSMenuItem(title: "\(session.label) — \(MenuBarController.displayText(for: state))", action: nil, keyEquivalent: "")
            header.image = MenuBarController.glyphImage(for: state.kind)
            let sub = NSMenu()
            let deviceId = session.deviceId
            sub.addItem(item(session.window.isVisible ? "Hide Window" : "Show Window") { [weak session] in session?.toggleVisibility() })
            sub.addItem(item("Reconnect") { [weak session] in session?.coordinator.reconnect() })
            sub.addItem(.separator())
            sub.addItem(item("Disconnect") { [weak self] in self?.onDisconnect(deviceId) })
            header.submenu = sub
            menu.addItem(header)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Another Goggles…") { [weak self] in self?.onOpenAnother() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GogglesView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Glyph

    private func updateGlyph() {
        let kinds = registry.all.map { $0.coordinator.uiState.kind }
        let category = MenuBarController.summaryCategory(kinds)
        statusItem.button?.image = MenuBarController.glyphImage(for: category)
        let summary = registry.all
            .map { "\($0.label): \(MenuBarController.displayText(for: $0.coordinator.uiState))" }
            .joined(separator: "; ")
        statusItem.button?.image?.accessibilityDescription = "GogglesView: \(summary.isEmpty ? "no goggles open" : summary)"
        statusItem.button?.toolTip = summary.isEmpty ? "GogglesView" : summary
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
        case .noHelper(let reason):
            return reason ?? "Helper not installed"
        case .noDevice:
            return "No goggles connected"
        case .claiming:
            return "Claiming USB interfaces…"
        case .claimFailed:
            return "Claim failed"
        case .resolving:
            return "Resolving…"
        case .handshaking(let elapsedSeconds):
            return "Handshaking… \(elapsedSeconds)s"
        case .waitingForKeyframe:
            return "Waiting for video…"
        case .live:
            guard let stats else { return "Live" }
            return ["Live", resolution, "\(stats.fps)fps"].compactMap { $0 }.joined(separator: " · ")
        case .stalled:
            return "Signal lost — reconnecting…"
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
#endif
