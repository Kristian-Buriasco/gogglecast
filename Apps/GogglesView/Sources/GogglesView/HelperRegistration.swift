import Foundation
import ServiceManagement

// ─────────────────────────────────────────────────────────────────────────
// task-gui-v2, settings-screen item: Task 2.4's `SMAppService.daemon`
// register/unregister/status logic, extracted out of `main.swift`'s
// `--register`/`--unregister`/`--check-daemon-status` CLI harness into one
// shared, reusable place.
//
// Before this file existed, that logic was effectively duplicated twice:
// `main.swift`'s top-level `plistName`/`service`/`describe(_:)` (Task 2.4,
// the CLI harness) and `GogglesConnectionCoordinator.setUpHelper()`'s own
// independent `SMAppService.daemon(plistName: "com.kburiasco...")` call with
// the plist-name string re-typed as a literal. The task-gui-v2 brief's
// settings screen needs this exact same register()/unregister()/status
// flow a THIRD time (Launch-at-login toggle, Re-register recovery button) --
// the brief is explicit about reusing the existing flow rather than
// reimplementing it again, so this is the point where that duplication
// actually gets fixed: one canonical `plistName`/`service`/register/
// unregister/describe, with `main.swift`'s CLI harness,
// `GogglesConnectionCoordinator.setUpHelper()`, and `SettingsViewModel` all
// now calling through this instead of each keeping their own copy.
// ─────────────────────────────────────────────────────────────────────────

/// The single source of truth for `com.kburiasco.gogglesview.helper.plist`
/// registration -- Task 2.4's design, unchanged behavior, just no longer
/// copy-pasted at each call site.
public enum HelperRegistration {
    public static let plistName = "com.kburiasco.gogglesview.helper.plist"

    /// A fresh `SMAppService.daemon(plistName:)` handle. Not cached: per
    /// Apple's own guidance and this app's existing usage elsewhere
    /// (`main.swift`'s top-level `service`), this is cheap to construct and
    /// always reflects the current registration, so there's no benefit to
    /// holding one instance alive across calls (and a small risk of it
    /// going stale relative to a fresh one if `ServiceManagement` ever
    /// changes that assumption).
    public static var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// The real, current status -- never cached/mirrored into an
    /// independent local boolean anywhere that reads this (see
    /// `SettingsViewModel`'s doc comment for why that matters for the
    /// Launch-at-login toggle specifically).
    public static var status: SMAppService.Status {
        service.status
    }

    /// Calls `register()` and returns the resulting status. Throws exactly
    /// what `SMAppService.register()` throws -- callers (the CLI harness,
    /// `SettingsViewModel`) decide how to surface that.
    @discardableResult
    public static func register() throws -> SMAppService.Status {
        try service.register()
        return service.status
    }

    /// Calls `unregister()` and returns the resulting status.
    @discardableResult
    public static func unregister() throws -> SMAppService.Status {
        try service.unregister()
        return service.status
    }

    /// UI/log-friendly text for a status value -- was `main.swift`'s
    /// top-level `describe(_:)` (Task 2.3/2.4), moved here so the Settings
    /// screen's helper-status display and the CLI harness's printed output
    /// use the exact same strings, not two independently-worded copies.
    /// Plain-language status for the UI (the raw `describe` stays for logs
    /// and the Diagnostics copy).
    public static func plainDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return L("Running and approved")
        case .requiresApproval: return L("Waiting for your approval in System Settings")
        case .notRegistered: return L("Not set up yet")
        case .notFound: return L("Not found. Reinstall GogglesView")
        @unknown default: return L("Unknown")
        }
    }

    /// Registers for a user-initiated action and returns a plain error
    /// sentence on failure (nil on success). Opens Login Items when macOS
    /// still needs approval. The real error is also logged.
    @discardableResult
    public static func registerForUser() -> String? {
        do {
            let status = try register()
            if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return nil
        } catch {
            Logging.xpc.error("helper register() failed: \(String(describing: error), privacy: .public)")
            ConnectionTrace.shared.record("helper register() failed: \(error)")
            return L("Couldn't set up the background service: %@", error.localizedDescription)
        }
    }

    public static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
