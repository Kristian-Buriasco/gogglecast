import Foundation
import ServiceManagement
#if canImport(SwiftUI)
import SwiftUI
#endif

// ─────────────────────────────────────────────────────────────────────────
// task-gui-v2 point 5: the Settings screen's real (not independently-tracked)
// `SMAppService` state -- see `HelperRegistration.swift` for the single
// shared register/unregister/status implementation this drives, and
// `SettingsView.swift` for the view this backs.
// ─────────────────────────────────────────────────────────────────────────

/// Owns the Settings screen's live `SMAppService.Status` and the two
/// actions that mutate it (Launch-at-login toggle, Re-register button).
/// Deliberately never introduces a second, independently-tracked "is launch
/// at login on" boolean: `isLaunchAtLoginEnabled` is a computed property
/// derived from `status` every time it's read, and `status` itself is
/// re-read from the real `HelperRegistration.status` (i.e.
/// `SMAppService.daemon(plistName:).status`) on `refresh()` (called from
/// `SettingsView`'s `.onAppear`) and by a light poll while the window is
/// open -- so an external change (the user approving/revoking the login
/// item from System Settings' Login Items & Extensions pane directly,
/// bypassing this app entirely) is picked up instead of leaving the toggle
/// showing stale state, exactly the failure mode the task brief calls out
/// ("not an independent local boolean that could drift from reality").
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    /// Short, transient feedback text under the toggle/buttons -- a failed
    /// register()/unregister() call's error, or a note that approval is
    /// pending. `nil` most of the time (no news is good news).
    @Published public private(set) var actionMessage: String?

    private var pollTimer: Timer?

    public init() {
        status = HelperRegistration.status
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Derived display state

    public var isLaunchAtLoginEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    public var statusDescription: String {
        "SMAppService.daemon: \(HelperRegistration.describe(status))"
    }

    #if canImport(SwiftUI)
    public var statusColor: Color {
        switch status {
        case .enabled: return .green
        case .requiresApproval: return .yellow
        case .notFound, .notRegistered: return .red
        @unknown default: return .gray
        }
    }
    #endif

    /// The "Re-register" recovery button (task brief: "for recovering from
    /// a broken/`.notFound` state") -- shown whenever the daemon isn't
    /// cleanly `.enabled`, not only for `.notFound` specifically, since
    /// `.notRegistered`/`.requiresApproval` are equally states where
    /// re-running `register()` is the right recovery action.
    public var showsReRegisterButton: Bool {
        status != .enabled
    }

    // MARK: - Actions

    /// Re-reads the real status and (idempotently) starts the light poll
    /// that keeps it live while the Settings window is open. Call from
    /// `SettingsView`'s `.onAppear`.
    public func refresh() {
        status = HelperRegistration.status
        startPollingIfNeeded()
    }

    /// Stop the poll -- call from `SettingsView`'s `.onDisappear` so a
    /// closed-but-not-yet-deallocated window (or, more likely, this view
    /// model outliving a brief window-close/reopen cycle) doesn't keep a
    /// `Timer` firing for no visible UI.
    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fresh = HelperRegistration.status
            if fresh != self.status {
                self.status = fresh
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// The Launch-at-login toggle's `set`. `enabled == true` calls
    /// `register()`; `false` calls `unregister()` -- both through
    /// `HelperRegistration`, both are the exact same underlying calls
    /// `main.swift --register`/`--unregister` make (Task 2.4).
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                let newStatus = try HelperRegistration.register()
                status = newStatus
                if newStatus == .requiresApproval {
                    actionMessage = "Requires approval — opening Login Items & Extensions…"
                    openLoginItemsSettings()
                } else {
                    actionMessage = nil
                }
            } else {
                status = try HelperRegistration.unregister()
                actionMessage = nil
            }
        } catch {
            actionMessage = "Failed: \(error.localizedDescription)"
            // Re-read the real status rather than trusting the toggle's
            // intended new value -- a failed register()/unregister() call
            // may have left the daemon in whatever state it was already in,
            // and the toggle must reflect that, not the failed attempt.
            status = HelperRegistration.status
        }
    }

    /// The "Re-register" recovery button's action.
    public func reRegister() {
        do {
            let newStatus = try HelperRegistration.register()
            status = newStatus
            actionMessage = newStatus == .enabled
                ? "Re-registered."
                : "Status: \(HelperRegistration.describe(newStatus))"
            if newStatus == .requiresApproval {
                openLoginItemsSettings()
            }
        } catch {
            actionMessage = "Re-register failed: \(error.localizedDescription)"
            status = HelperRegistration.status
        }
    }
}
