import Foundation
#if canImport(AppKit)
import AppKit
import Combine
import SwiftUI
#endif

// Automatic markers: while a recording runs, noteworthy events are added to it as markers (and so
// as chapters in the finished file). Pure decision logic (`AutoMarkerPolicy`) with the clock passed
// in, user prefs (`AutoMarkerPrefs`) and a thin controller per goggles window. Signal and battery
// events are the ones the event hooks already use (debounced / threshold crossing), never a second
// detector.

enum AutoMarkerPrefs {
    static let enabledKey = "autoMarkers"
    static let signalKey = "autoMarkersSignal"
    static let batteryKey = "autoMarkersBattery"
    static let capturesKey = "autoMarkersCaptures"
    static let raceKey = "autoMarkersRace"

    static var allKeys: [String] { [enabledKey, signalKey, batteryKey, capturesKey, raceKey] }

    static func bool(_ key: String, _ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: key) as? Bool ?? true
    }

    static func config(_ d: UserDefaults = .standard) -> AutoMarkerPolicy.Config {
        .init(enabled: bool(enabledKey, d), signal: bool(signalKey, d), battery: bool(batteryKey, d),
              captures: bool(capturesKey, d), race: bool(raceKey, d))
    }
}

/// Decides which events become markers. Pure: every call gets the time it happened at.
struct AutoMarkerPolicy {
    enum Event: Equatable {
        case signalLost, signalRestored
        /// The goggles battery crossed the low threshold (the same crossing the battery hook reports).
        case batteryLow(percent: Int)
        case replaySaved, screenshotTaken
        case raceMode(on: Bool)
    }

    struct Config: Equatable {
        var enabled = true
        var signal = true
        var battery = true
        var captures = true
        var race = true
    }

    /// Two markers with the same label closer than this are one marker.
    static let dedupeWindow: TimeInterval = 2

    var config: Config
    private var lastAt: [String: Date] = [:]
    private var batteryMarked = false
    private var lostMarked = false

    init(config: Config = Config()) { self.config = config }

    /// Call when a new recording starts: the once-per-recording battery marker is available again.
    mutating func recordingStarted() {
        lastAt = [:]
        batteryMarked = false
        lostMarked = false
    }

    static func label(for event: Event) -> String {
        switch event {
        case .signalLost: return L("Signal lost")
        case .signalRestored: return L("Signal restored")
        case .batteryLow(let p): return L("Goggles battery low (%lld%%)", p)
        case .replaySaved: return L("Replay saved")
        case .screenshotTaken: return L("Screenshot taken")
        case .raceMode(let on): return on ? L("Race mode on") : L("Race mode off")
        }
    }

    private func isEnabled(_ event: Event) -> Bool {
        guard config.enabled else { return false }
        switch event {
        case .signalLost, .signalRestored: return config.signal
        case .batteryLow: return config.battery
        case .replaySaved, .screenshotTaken: return config.captures
        case .raceMode: return config.race
        }
    }

    /// The marker label to add for `event` at `time`, or nil (switched off, a repeat, or the battery
    /// marker was already used in this recording). Only call while recording.
    mutating func marker(for event: Event, at time: Date) -> String? {
        guard isEnabled(event) else { return nil }
        if case .batteryLow = event, batteryMarked { return nil }
        // The hooks announce the first live picture as "live"; that is not a restore unless a loss was marked.
        if event == .signalRestored, !lostMarked { return nil }
        let text = Self.label(for: event)
        // Battery text carries the percentage, so compare on the kind of event instead.
        let key: String
        if case .batteryLow = event { key = "battery" } else { key = text }
        if let last = lastAt[key], abs(time.timeIntervalSince(last)) < Self.dedupeWindow { return nil }
        lastAt[key] = time
        if case .batteryLow = event { batteryMarked = true }
        if event == .signalLost { lostMarked = true }
        if event == .signalRestored { lostMarked = false }
        return text
    }
}

#if canImport(AppKit)
extension Notification.Name {
    /// Posted by `EventHookInstaller` right after it hands a debounced stream event or a battery
    /// crossing to the hooks. userInfo: "event" (AppEvent), "deviceId" (String), "percent" (Int, battery only).
    static let gogglesHookEventFired = Notification.Name("GogglesHookEventFired")
}

/// One per goggles window: turns the hook events and the capture notifications of that window into
/// markers on its recorder.
final class AutoMarkerController {
    private var policy = AutoMarkerPolicy(config: AutoMarkerPrefs.config())
    private let now: () -> Date
    private let isRecording: () -> Bool
    private let addMarker: (String) -> Void
    private let config: () -> AutoMarkerPolicy.Config
    private var bag = Set<AnyCancellable>()

    /// `session` is the window's `DecodeSession`; replay and screenshot notifications carry it as their object.
    init(deviceId: String, session: AnyObject,
         isRecording: @escaping () -> Bool, addMarker: @escaping (String) -> Void,
         now: @escaping () -> Date = Date.init, center: NotificationCenter = .default,
         config: @escaping () -> AutoMarkerPolicy.Config = { AutoMarkerPrefs.config() }) {
        self.now = now
        self.config = config
        self.isRecording = isRecording
        self.addMarker = addMarker
        center.publisher(for: .gogglesHookEventFired)
            .sink { [weak self] n in
                guard (n.userInfo?["deviceId"] as? String) == deviceId, let e = n.userInfo?["event"] as? AppEvent else { return }
                switch e {
                case .streamLost: self?.handle(.signalLost)
                case .streamLive: self?.handle(.signalRestored)
                case .batteryLow: self?.handle(.batteryLow(percent: n.userInfo?["percent"] as? Int ?? 0))
                default: break
                }
            }.store(in: &bag)
        center.publisher(for: .gogglesRecordingStarted)
            .sink { [weak self] n in if n.object as AnyObject? === session { self?.policy.recordingStarted() } }
            .store(in: &bag)
        center.publisher(for: .gogglesReplaySaved)
            .sink { [weak self] n in if n.object as AnyObject? === session { self?.handle(.replaySaved) } }
            .store(in: &bag)
        center.publisher(for: .gogglesScreenshotSaved)
            .sink { [weak self] n in if n.object as AnyObject? === session { self?.handle(.screenshotTaken) } }
            .store(in: &bag)
        center.publisher(for: .gogglesRaceModeChanged)
            .sink { [weak self] n in
                guard let on = n.userInfo?["on"] as? Bool else { return }
                self?.handle(.raceMode(on: on))
            }.store(in: &bag)
    }

    /// Notifications may come from writer completion queues; the policy is only touched on main.
    func handle(_ event: AutoMarkerPolicy.Event) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.handle(event) }; return }
        guard isRecording() else { return }
        policy.config = config()
        if let text = policy.marker(for: event, at: now()) { addMarker(text) }
    }
}

/// Settings > Recording: which events add markers by themselves.
struct AutoMarkerSettingsSection: View {
    @AppStorage(AutoMarkerPrefs.enabledKey) private var enabled = true
    @AppStorage(AutoMarkerPrefs.signalKey) private var signal = true
    @AppStorage(AutoMarkerPrefs.batteryKey) private var battery = true
    @AppStorage(AutoMarkerPrefs.capturesKey) private var captures = true
    @AppStorage(AutoMarkerPrefs.raceKey) private var race = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Automatic markers").font(.headline)
            Toggle("Add markers to recordings automatically", isOn: $enabled)
                .accessibilityIdentifier("autoMarkersToggle")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Signal lost and restored", isOn: $signal)
                Toggle("Goggles battery low (once per recording)", isOn: $battery)
                Toggle("Replay saved and screenshot taken", isOn: $captures)
                Toggle("Race mode turned on or off", isOn: $race)
            }
            .padding(.leading, 16)
            .disabled(!enabled)
            Text("Markers appear in the clip's .markers.json and as chapters in QuickTime Player, Final Cut, Resolve and VLC. They are drawn in a different colour from your own markers when you trim.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
#endif
