import Foundation

extension Notification.Name {
    /// Posted (object: the target `DecodeSession`) to start/stop that
    /// window's UDP network stream; `NetworkStreamControl` handles it.
    static let gogglesToggleNetworkStream = Notification.Name("GogglesToggleNetworkStream")
    /// Posted when a per-window control registers with `SessionControlBoard`.
    static let gogglesControlBoardChanged = Notification.Name("GogglesControlBoardChanged")
}

/// "Show menu bar item" preference (Settings > General). Defaults to on.
enum MenuBarPrefs {
    static let showKey = "showMenuBarItem"
    static func show(defaults d: UserDefaults = .standard) -> Bool {
        d.object(forKey: showKey) == nil ? true : d.bool(forKey: showKey)
    }
}

/// Everything the menu-bar mini-controls need to know about one goggles
/// window, captured when the menu opens. Pure value, built by
/// `MenuBarController` from the live session objects.
struct MiniControlsSnapshot: Equatable {
    var label: String
    /// `MenuBarController.displayText(for:)` of the coordinator state.
    var statusText: String
    var isLive: Bool
    var fps: Int?
    var batteryPercent: Int?
    var isRecording: Bool = false
    var recordingElapsed: TimeInterval = 0
    var isFrozen: Bool = false
    var isNetworkStreaming: Bool = false
    /// The window's network-stream control is mounted (it owns the streamer).
    var networkStreamAvailable: Bool = false
    var replayEnabled: Bool = false
    var isWindowVisible: Bool = true
}

enum MiniControlAction: CaseIterable, Equatable {
    case toggleRecording, saveReplay, screenshot, toggleFreeze, addMarker, showWindow, toggleNetworkStream

    /// Actions that already have a global-hotkey notification are dispatched
    /// through it (same handlers, same per-window routing).
    var hotkeyAction: GlobalHotkeyAction? {
        switch self {
        case .toggleRecording: return .toggleRecording
        case .saveReplay: return .saveReplay
        case .screenshot: return .screenshot
        default: return nil
        }
    }
}

struct MiniControlItem: Equatable {
    let action: MiniControlAction
    let title: String
    let isEnabled: Bool
    /// Shown as a checkmark (recording, frozen, streaming).
    let isOn: Bool
}

/// Pure title/state/enabled computation for the status-item menu (unit-tested).
enum MenuBarMiniControls {
    /// "03:07" -- same format as the window's record control.
    static func formatElapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Per-device submenu title: "DJI Goggles 3 (…1234) — Live · ● REC 01:23".
    static func headerTitle(_ s: MiniControlsSnapshot) -> String {
        var title = "\(s.label) — \(s.statusText)"
        if s.isRecording { title += " · ● REC \(formatElapsed(s.recordingElapsed))" }
        return title
    }

    /// Disabled info line at the top of the submenu: "60 fps · Battery 80% · Recording 01:23".
    static func infoLine(_ s: MiniControlsSnapshot) -> String {
        var parts: [String] = []
        if s.isLive, let fps = s.fps { parts.append("\(fps) fps") } else { parts.append("— fps") }
        if let battery = s.batteryPercent { parts.append("Battery \(battery)%") }
        parts.append(s.isRecording ? "Recording \(formatElapsed(s.recordingElapsed))" : "Not recording")
        return parts.joined(separator: " · ")
    }

    /// Mirrors the enabled rules of the window's own footer controls.
    static func items(_ s: MiniControlsSnapshot) -> [MiniControlItem] {
        [
            MiniControlItem(action: .toggleRecording, title: s.isRecording ? "Stop Recording" : "Start Recording",
                            isEnabled: s.isRecording || s.isLive, isOn: s.isRecording),
            MiniControlItem(action: .saveReplay, title: s.replayEnabled ? "Save Replay" : "Save Replay (off in Settings)",
                            isEnabled: s.replayEnabled && s.isLive, isOn: false),
            MiniControlItem(action: .screenshot, title: "Screenshot", isEnabled: s.isLive, isOn: false),
            MiniControlItem(action: .toggleFreeze, title: s.isFrozen ? "Resume Video" : "Freeze Video",
                            isEnabled: s.isLive || s.isFrozen, isOn: s.isFrozen),
            MiniControlItem(action: .addMarker, title: "Add Marker", isEnabled: s.isRecording, isOn: false),
            MiniControlItem(action: .showWindow, title: s.isWindowVisible ? "Hide Window" : "Show Window",
                            isEnabled: true, isOn: false),
            MiniControlItem(action: .toggleNetworkStream,
                            title: s.isNetworkStreaming ? "Stop Network Stream" : "Start Network Stream",
                            isEnabled: s.networkStreamAvailable, isOn: s.isNetworkStreaming),
        ]
    }

    static func anyRecording(_ snapshots: [MiniControlsSnapshot]) -> Bool {
        snapshots.contains { $0.isRecording }
    }
}

/// Per-window controls whose state lives in SwiftUI `@StateObject`s
/// (recorder, network streamer) register here so the menu-bar item can read
/// their state. Keyed by the window's `DecodeSession`; weak, main thread only.
final class SessionControlBoard {
    static let shared = SessionControlBoard()

    private struct Entry {
        weak var recorder: Recorder?
        weak var streamer: NetworkStreamer?
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(recorder: Recorder, for session: AnyObject) {
        entries[ObjectIdentifier(session), default: Entry()].recorder = recorder
        NotificationCenter.default.post(name: .gogglesControlBoardChanged, object: session)
    }

    func register(streamer: NetworkStreamer, for session: AnyObject) {
        entries[ObjectIdentifier(session), default: Entry()].streamer = streamer
        NotificationCenter.default.post(name: .gogglesControlBoardChanged, object: session)
    }

    func recorder(for session: AnyObject) -> Recorder? { entries[ObjectIdentifier(session)]?.recorder }
    func streamer(for session: AnyObject) -> NetworkStreamer? { entries[ObjectIdentifier(session)]?.streamer }

    func unregister(_ session: AnyObject) { entries[ObjectIdentifier(session)] = nil }
}
