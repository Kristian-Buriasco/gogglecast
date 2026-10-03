#if canImport(AppKit)
import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// task-gui-v2 point 5: opens/reuses a single, genuine `NSWindow` hosting
// `SettingsView` -- a plain on-demand window (not a SwiftUI `Settings`
// scene: this app isn't structured on the `App`/`Scene` lifecycle at all --
// see `MenuBarController.swift`'s doc comment for the identical reasoning
// applied to `MenuBarExtra`), consistent with how the main window and menu
// bar item are already built imperatively in `main.swift`. NOT a sheet on
// the main video window -- a fully separate window, per the task brief.
// ─────────────────────────────────────────────────────────────────────────

/// Owns the Settings window + its `SettingsViewModel` for the app's
/// lifetime. Kept alive as a stored property wherever it's constructed
/// (mirrors `main.swift`'s `menuBarController`) -- `NSWindow` doesn't keep
/// itself alive, and rebuilding `SettingsViewModel` from scratch on every
/// open/close would drop its poll timer and any in-flight action message
/// for no reason, when the window can just be hidden and reshown instead.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: SettingsViewModel

    /// No `onReconnect` parameter: Settings is built once, at app launch,
    /// before any device is selected (so it's reachable from the device
    /// picker too -- see `main.swift`) -- there is no
    /// `GogglesConnectionCoordinator.reconnect()` to call yet at that
    /// point. Call `setReconnectHandler(_:)` once one exists.
    override init() {
        let viewModel = SettingsViewModel()
        self.viewModel = viewModel
        let view = SettingsView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        // Matches `main.swift`'s `sizingOptions = []` fix (Task 3.5) --
        // this window's content is a fixed-size settings form, not
        // `.frame(maxWidth: .infinity, ...)` content, so this mostly just
        // keeps behavior consistent/predictable rather than fixing a
        // visible bug here specifically.
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = "GogglesView Settings"
        // No `.resizable` -- this is a small, fixed-content settings panel,
        // not a resizable document window; matches the fixed
        // `.frame(width:height:)` `SettingsView` sets on itself.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 400, height: 680))
        // Survive being closed (red button / Cmd+W) instead of being
        // deallocated -- `show()` reuses the same window/view
        // model on the next open, same "hide, don't destroy" pattern
        // `HideOnCloseWindowDelegate` uses for the main window, just via
        // AppKit's own `isReleasedWhenClosed` instead of a custom delegate
        // override (this window's normal close behavior -- actually closing
        // rather than merely hiding -- is fine to keep here: the real
        // requirement is only that reopening it later doesn't require
        // reconstructing `SettingsViewModel`, which `isReleasedWhenClosed
        // = false` alone already guarantees).
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        super.init()
        window.delegate = self
        // task-gui-v2 point 4: same custom title bar as the main window, so
        // Settings reads as the same app, not a jarring native-chrome popup
        // next to the borderless main window.
        applyCustomTitleBarChrome(to: window)
    }

    /// Shows (or re-shows, if previously closed) the Settings window,
    /// refreshing the real `SMAppService` status first -- covers the case
    /// where the user changed the Login Item's approval state in System
    /// Settings while this window was closed.
    func show() {
        viewModel.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called once a device is selected and a real
    /// `GogglesConnectionCoordinator` exists -- wires the Settings
    /// screen's "Reconnect" button (previously disabled/absent) to
    /// `coordinator.reconnect()`, the exact same call the menu bar's
    /// "Reconnect" item makes.
    func setReconnectHandler(_ handler: @escaping () -> Void) {
        viewModel.reconnectHandler = handler
    }

    /// Wired once a `DecodeSession` exists; also applies the saved preference immediately.
    func setCaptureWindowHandler(_ handler: @escaping (_ enabled: Bool, _ onTop: Bool) -> Void) {
        viewModel.captureWindowHandler = handler
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        viewModel.stopPolling()
    }
}
#endif
