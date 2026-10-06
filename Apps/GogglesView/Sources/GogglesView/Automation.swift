import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

// Automation surface: the `gogglesview://` URL scheme (Shortcuts "Open URL",
// `open`, Stream Deck, Raycast) and the AppleScript suite (AppleScript.swift +
// BundleResources/GogglesView.sdef) both funnel into `AutomationController
// .perform`, which reuses the same per-window notification dispatch as the
// global hotkeys (`GlobalHotkeyRouting`), so no recording/screenshot logic is
// duplicated here.
//
// Security: commands only start/stop things that already exist in the UI.
// Nothing taken from a URL or script is ever used as a file path, shell
// command or network host -- the UDP stream uses the host/port from Settings.

extension Notification.Name {
    static let gogglesStartRecording = Notification.Name("GogglesStartRecording")
    static let gogglesStopRecording = Notification.Name("GogglesStopRecording")
    /// userInfo["label"]: String (already sanitized).
    static let gogglesAddMarker = Notification.Name("GogglesAddMarker")
    static let gogglesNetworkStreamStart = Notification.Name("GogglesNetworkStreamStart")
    static let gogglesNetworkStreamStop = Notification.Name("GogglesNetworkStreamStop")
}

enum AutomationPrefs {
    static let enabledKey = "automationEnabled"
    /// Default ON (an unset key counts as enabled). Governs AppleScript and URL commands alike.
    static func enabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: enabledKey) == nil ? true : d.bool(forKey: enabledKey)
    }

    static let urlEnabledKey = "automationURLEnabled"
    /// `gogglesview://` URL commands are OFF unless the user turns them on: any web page can open a URL.
    static func urlEnabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: urlEnabledKey) }
}

/// Decides what happens to a parsed `gogglesview://` request (pure, unit-tested).
struct AutomationURLGate {
    enum Decision: Equatable {
        /// Switch is off; this is the first ignored command this launch, so tell the user once.
        case ignoredNotify
        case ignored
        case rateLimited
        case allowed
    }

    static let maxPerWindow = 3
    static let window: TimeInterval = 1

    private var notified = false
    private var recent: [Date] = []

    mutating func decide(urlEnabled: Bool, now: Date = Date()) -> Decision {
        guard urlEnabled else {
            if notified { return .ignored }
            notified = true
            return .ignoredNotify
        }
        recent.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard recent.count < Self.maxPerWindow else { return .rateLimited }
        recent.append(now)
        return .allowed
    }
}

extension AutomationCommand {
    /// Short human description for the on-screen notice.
    var noticeText: String {
        switch self {
        case .startRecording: return "Start recording"
        case .stopRecording: return "Stop recording"
        case .toggleRecording: return "Toggle recording"
        case .saveReplay: return "Save replay"
        case .screenshot: return "Screenshot"
        case .toggleFreeze: return "Freeze / resume video"
        case .addMarker: return "Add marker"
        case .startStream: return "Start network stream"
        case .stopStream: return "Stop network stream"
        case .showWindow: return "Show window"
        }
    }
}

enum AutomationCommand: Equatable {
    case startRecording, stopRecording, toggleRecording
    case saveReplay
    case screenshot
    case toggleFreeze
    case addMarker(label: String)
    case startStream, stopStream
    case showWindow
}

struct AutomationRequest: Equatable {
    let command: AutomationCommand
    /// Serial (or helper deviceId) of the target goggles; nil = frontmost.
    let device: String?
}

/// Pure `gogglesview://` URL -> request parser (unit-tested). Returns nil for
/// anything it doesn't fully understand, so malformed input is a no-op.
enum AutomationURLParser {
    static let scheme = "gogglesview"
    static let defaultMarkerLabel = "Marker"
    static let maxDeviceLength = 64
    static let maxLabelLength = 64

    /// Every accepted path, for docs and the Settings helper.
    static let examplePaths = [
        "record/start", "record/stop", "record/toggle", "replay/save", "screenshot",
        "freeze/toggle", "marker", "stream/start", "stream/stop", "window/show",
    ]

    static func parse(_ url: URL) -> AutomationRequest? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == scheme,
              comps.user == nil, comps.password == nil, comps.port == nil, comps.fragment == nil
        else { return nil }

        // `gogglesview://record/start` -> host "record", path "/start".
        var parts: [String] = []
        if let host = comps.host, !host.isEmpty { parts.append(host) }
        parts += comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        let key = parts.map { $0.lowercased() }.joined(separator: "/")

        var device: String?
        var label: String?
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "device":
                guard device == nil, let v = item.value, let clean = sanitizeDevice(v) else { return nil }
                device = clean
            case "label":
                guard label == nil else { return nil }
                label = item.value.flatMap(sanitizeLabel)
            default:
                continue // unknown parameters are ignored, never interpreted
            }
        }

        let command: AutomationCommand
        switch key {
        case "record/start": command = .startRecording
        case "record/stop": command = .stopRecording
        case "record/toggle": command = .toggleRecording
        case "replay/save": command = .saveReplay
        case "screenshot": command = .screenshot
        case "freeze/toggle": command = .toggleFreeze
        case "marker": command = .addMarker(label: label ?? defaultMarkerLabel)
        case "stream/start": command = .startStream
        case "stream/stop": command = .stopStream
        case "window/show": command = .showWindow
        default: return nil
        }
        return AutomationRequest(command: command, device: device)
    }

    /// Serials/deviceIds are short alphanumerics; anything else is rejected.
    static func sanitizeDevice(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v.count <= maxDeviceLength else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard v.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return v
    }

    /// Marker labels are plain text in a JSON sidecar: strip control
    /// characters, trim, cap the length. Empty -> nil (caller uses default).
    static func sanitizeLabel(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let v = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return String(v.prefix(maxLabelLength))
    }

    static func exampleURL(_ path: String) -> String { "\(scheme)://\(path)" }
}

/// Picks the session a command targets (unit-tested with plain values).
enum AutomationTargeting {
    /// With `device`: the session whose serial or deviceId matches
    /// (case-insensitive), else nil -- never falls back to another device.
    /// Without: the frontmost session, else the only one.
    static func pick<T>(device: String?, sessions: [T], frontmost: T?, identifiers: (T) -> [String?]) -> T? {
        if let device {
            let needle = device.lowercased()
            return sessions.first { identifiers($0).contains { $0?.lowercased() == needle } }
        }
        return frontmost ?? (sessions.count == 1 ? sessions[0] : nil)
    }
}

#if canImport(AppKit)

/// Per-window recording flag for the read-only AppleScript `recording`
/// property. The recorder itself is owned by the window's SwiftUI view.
final class AutomationRecordingState {
    static let shared = AutomationRecordingState()
    private let table = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    func set(_ recording: Bool, for session: AnyObject) { table.setObject(NSNumber(value: recording), forKey: session) }
    func isRecording(_ session: AnyObject) -> Bool { table.object(forKey: session)?.boolValue ?? false }
}

enum AutomationResult: Equatable {
    case done
    case disabled
    case noTarget
}

/// Routes requests to goggles windows. Installed once by `main.swift`.
final class AutomationController: NSObject {
    static let shared = AutomationController()
    private static let log = Logger(subsystem: Logging.subsystem, category: "Automation")

    private var sessions: () -> [GogglesSession] = { [] }
    private var frontmost: () -> GogglesSession? = { nil }
    private var showWithoutSession: () -> Void = {}

    func install(sessions: @escaping () -> [GogglesSession],
                 frontmost: @escaping () -> GogglesSession?,
                 showWithoutSession: @escaping () -> Void) {
        self.sessions = sessions
        self.frontmost = frontmost
        self.showWithoutSession = showWithoutSession
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        handle(url: url)
    }

    private var urlGate = AutomationURLGate()

    /// URL entry point. Web pages can open `gogglesview://` links, so URL commands need their own
    /// opt-in switch (default off), are rate limited, and are announced on screen. AppleScript calls
    /// `perform` directly and is unaffected.
    @discardableResult
    func handle(url: URL, defaults: UserDefaults = .standard, notify: (String) -> Void = { ToastHUD.shared.show($0) }) -> AutomationResult? {
        guard let request = AutomationURLParser.parse(url) else {
            Self.log.info("ignored unrecognized URL")
            return nil
        }
        switch urlGate.decide(urlEnabled: AutomationPrefs.urlEnabled(defaults)) {
        case .ignoredNotify:
            Self.log.info("URL command ignored (URL commands are off)")
            notify("A gogglesview:// command was ignored. To allow URL commands, turn on Settings > Advanced > Automation > Allow gogglesview:// URL commands.")
            return .disabled
        case .ignored:
            Self.log.info("URL command ignored (URL commands are off)")
            return .disabled
        case .rateLimited:
            Self.log.info("URL command dropped (rate limit)")
            return nil
        case .allowed:
            notify("URL command: \(request.command.noticeText)")
        }
        let result = perform(request)
        Self.log.info("\(String(describing: request.command), privacy: .public) -> \(String(describing: result), privacy: .public)")
        return result
    }

    var openSessions: [GogglesSession] { sessions() }

    /// The session a request targets (also used by the AppleScript properties).
    func target(device: String?) -> GogglesSession? {
        AutomationTargeting.pick(device: device, sessions: sessions(), frontmost: frontmost()) {
            [$0.coordinator.deviceInfo?.serial, $0.deviceId]
        }
    }

    func perform(_ request: AutomationRequest) -> AutomationResult {
        guard AutomationPrefs.enabled() else { return .disabled }
        guard let session = target(device: request.device) else {
            if request.command == .showWindow, request.device == nil {
                showWithoutSession()
                return .done
            }
            return .noTarget
        }
        let target = session.decodeSession
        func post(_ name: Notification.Name, _ info: [AnyHashable: Any]? = nil) {
            NotificationCenter.default.post(name: name, object: target, userInfo: info)
        }
        switch request.command {
        case .startRecording: post(.gogglesStartRecording)
        case .stopRecording: post(.gogglesStopRecording)
        case .toggleRecording: post(.gogglesToggleRecording)
        case .saveReplay: post(.gogglesSaveReplay)
        case .screenshot: post(.gogglesScreenshot)
        case .toggleFreeze: target.freezeState.toggle()
        case .addMarker(let label): post(.gogglesAddMarker, ["label": label])
        case .startStream: post(.gogglesNetworkStreamStart)
        case .stopStream: post(.gogglesNetworkStreamStop)
        case .showWindow: session.focus()
        }
        return .done
    }
}
#endif
