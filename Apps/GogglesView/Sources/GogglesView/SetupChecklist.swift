import Foundation
import ServiceManagement

/// Pure logic behind the "why aren't my goggles showing" checklist
/// (device picker empty state, onboarding, self-test). No UI, no I/O.
struct SetupChecklist {
    enum Registration: Equatable {
        case enabled, requiresApproval, notRegistered, notFound, unknown

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notRegistered: self = .notRegistered
            case .notFound: self = .notFound
            @unknown default: self = .unknown
            }
        }
    }

    enum Reachability: Equatable {
        case connected, connecting, disconnected, versionMismatch
        /// No client available (e.g. onboarding before a connection exists).
        case unknown

        init(_ state: HelperClientConnectionState) {
            switch state {
            case .connected: self = .connected
            case .connecting: self = .connecting
            case .disconnected: self = .disconnected
            case .versionMismatch: self = .versionMismatch
            }
        }
    }

    enum Status: Equatable { case pass, fail, unknown }

    enum Action: Equatable { case openLoginItems }

    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        let status: Status
        /// Specific fix text; `nil` when passing.
        let fix: String?
        let action: Action?
    }

    static let loginItemsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    static func items(registration: Registration, reachability: Reachability, devicesFound: Int?) -> [Item] {
        let regItem: Item
        switch registration {
        case .enabled:
            regItem = Item(id: "helper-registered", title: "Helper approved and registered", status: .pass, fix: nil, action: nil)
        case .requiresApproval:
            regItem = Item(id: "helper-registered", title: "Helper needs approval", status: .fail,
                           fix: "Approve GogglesView in System Settings > Login Items & Extensions.", action: .openLoginItems)
        case .notRegistered, .notFound:
            regItem = Item(id: "helper-registered", title: "Helper not registered", status: .fail,
                           fix: "Register the helper from Settings > General (Re-register), then approve it in System Settings > Login Items & Extensions.",
                           action: .openLoginItems)
        case .unknown:
            regItem = Item(id: "helper-registered", title: "Helper registration unknown", status: .unknown, fix: nil, action: nil)
        }

        let reachItem: Item
        switch reachability {
        case .connected:
            reachItem = Item(id: "helper-reachable", title: "Helper reachable", status: .pass, fix: nil, action: nil)
        case .connecting:
            reachItem = Item(id: "helper-reachable", title: "Connecting to helper…", status: .unknown, fix: nil, action: nil)
        case .unknown:
            reachItem = Item(id: "helper-reachable", title: "Helper reachability not checked", status: .unknown, fix: nil, action: nil)
        case .disconnected:
            reachItem = Item(id: "helper-reachable", title: "Helper not reachable", status: .fail,
                             fix: registration == .enabled
                                ? "The helper is registered but not answering. Use Settings > General > Reconnect or Re-register."
                                : "Fix helper registration above first.",
                             action: nil)
        case .versionMismatch:
            reachItem = Item(id: "helper-reachable", title: "Helper version mismatch", status: .fail,
                             fix: "The installed helper is from a different GogglesView version. Re-register it from Settings > General, or reinstall the app.",
                             action: nil)
        }

        let usbItem: Item
        if reachability != .connected {
            usbItem = Item(id: "usb-device", title: "Goggles USB device", status: .unknown, fix: nil, action: nil)
        } else if let n = devicesFound, n > 0 {
            usbItem = Item(id: "usb-device", title: "Goggles seen on USB", status: .pass, fix: nil, action: nil)
        } else if devicesFound == 0 {
            usbItem = Item(id: "usb-device", title: "No goggles seen on USB", status: .fail,
                           fix: "On the goggles enable Settings > About > OTG Wired Connection to Computer (unplug the cable before toggling). Use a USB-C data cable (not charge-only) and try another port.",
                           action: nil)
        } else {
            usbItem = Item(id: "usb-device", title: "Goggles USB device", status: .unknown, fix: nil, action: nil)
        }
        return [regItem, reachItem, usbItem]
    }
}

/// Frame/fps accounting for the opt-in stream self-test.
struct StreamTestMeter {
    private(set) var frames = 0
    private(set) var firstFrameAt: TimeInterval?

    mutating func recordFrame(at t: TimeInterval) {
        if firstFrameAt == nil { firstFrameAt = t }
        frames += 1
    }

    var gotFirstFrame: Bool { firstFrameAt != nil }

    /// Frames per second over [firstFrame, end]; `nil` before 2 frames or with no elapsed time.
    func fps(endingAt end: TimeInterval) -> Double? {
        guard let first = firstFrameAt, frames >= 2, end > first else { return nil }
        return Double(frames - 1) / (end - first)
    }
}
