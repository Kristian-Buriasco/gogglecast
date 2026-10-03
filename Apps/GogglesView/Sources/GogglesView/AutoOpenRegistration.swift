import Foundation
import ServiceManagement

/// Opt-in per-user LaunchAgent that launches/activates the app when the goggles
/// (USB 2CA3:0020) appear. launchd's `com.apple.iokit.matching` LaunchEvent
/// runs `open -b com.kburiasco.gogglesview`; if the app is already running,
/// LaunchServices just activates it (no second instance).
public enum AutoOpenRegistration {
    public static let plistName = "com.kburiasco.gogglesview.autoopen.plist"

    public static var service: SMAppService { SMAppService.agent(plistName: plistName) }
    public static var status: SMAppService.Status { service.status }
    /// `requiresApproval` counts as "on": the user opted in, macOS just wants a click.
    public static var isOptedIn: Bool { status == .enabled || status == .requiresApproval }

    @discardableResult
    public static func register() throws -> SMAppService.Status {
        try service.register()
        return service.status
    }

    @discardableResult
    public static func unregister() throws -> SMAppService.Status {
        try service.unregister()
        return service.status
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
