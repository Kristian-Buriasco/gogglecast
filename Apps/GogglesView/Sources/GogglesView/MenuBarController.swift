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

/// Owns the `NSStatusItem`: state glyph, "Reconnect", show/hide the main
/// window, "Quit". Created once in `main.swift`'s real-app launch path and
/// kept alive for the app's lifetime (stored in a top-level `var` there --
/// `NSStatusItem` does not keep itself alive, and `statusItem.menu`/
/// `NSMenuItem.target` are unowned/weak-ish references that need a living
/// owner).
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: GogglesConnectionCoordinator
    private weak var window: NSWindow?

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleWindowItem = NSMenuItem(title: "", action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
    private let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(MenuActionTarget.invoke), keyEquivalent: "r")

    // Targets kept alive as stored properties for the same reason as
    // `main.swift`'s (now-relocated) Task 3.5 "Goggles > Reconnect" item --
    // `NSMenuItem.target` is a weak/unowned-ish reference under the hood, so
    // whatever object implements the `@objc` action needs a real owner.
    private let toggleWindowTarget: MenuActionTarget
    private let reconnectTarget: MenuActionTarget

    private var uiStateCancellable: AnyCancellable?

    init(coordinator: GogglesConnectionCoordinator, window: NSWindow) {
        self.coordinator = coordinator
        self.window = window
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.reconnectTarget = MenuActionTarget { coordinator.reconnect() }
        self.toggleWindowTarget = MenuActionTarget { [weak window] in
            guard let window else { return }
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        super.init()

        reconnectItem.target = reconnectTarget
        toggleWindowItem.target = toggleWindowTarget
        stateItem.isEnabled = false

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(reconnectItem)
        menu.addItem(toggleWindowItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GogglesView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        updateGlyph(for: coordinator.uiState)
        uiStateCancellable = coordinator.$uiState.sink { [weak self] state in
            self?.updateGlyph(for: state)
        }
    }

    // MARK: - NSMenuDelegate

    /// Refresh the two dynamic lines (state text, show/hide title) right
    /// before the menu opens, rather than only reacting to
    /// `coordinator.$uiState` -- `window.isVisible` isn't `@Published`
    /// anywhere the coordinator can see, so this is the simplest correct
    /// place to pick up window-visibility changes the user made some other
    /// way (e.g. the titlebar's own controls, once fullscreened/minimized).
    func menuWillOpen(_ menu: NSMenu) {
        updateGlyph(for: coordinator.uiState)
        toggleWindowItem.title = (window?.isVisible ?? false) ? "Hide GogglesView" : "Show GogglesView"
    }

    // MARK: - Glyph

    private func updateGlyph(for state: GogglesUIState) {
        stateItem.title = MenuBarController.displayText(for: state)
        statusItem.button?.image = MenuBarController.glyphImage(for: state.kind)
        statusItem.button?.image?.accessibilityDescription = "GogglesView: \(MenuBarController.displayText(for: state))"
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
    static func displayText(for state: GogglesUIState, stats: StreamStats? = nil) -> String {
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
            return "Live · 1920x1080 · \(stats.fps)fps"
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
        let symbolName: String
        let color: NSColor
        switch kind.statusGlyphCategory {
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
