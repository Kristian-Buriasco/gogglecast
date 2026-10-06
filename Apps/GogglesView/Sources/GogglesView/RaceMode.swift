import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// Race mode: one switch for the lowest-latency preview. It only changes the preview path
// (what the video window shows). Recording passthrough and the streaming outputs are not
// touched, and it never turns the re-encode hub on. See docs/latency.md, "Race mode".

extension Notification.Name {
    /// Posted on the main queue after the effective race mode value changed.
    static let gogglesRaceModeChanged = Notification.Name("GogglesRaceModeChanged")
}

enum RaceModePrefs {
    static let key = "raceMode"

    static func isEnabled(_ d: UserDefaults) -> Bool { d.bool(forKey: key) }
    static var enabled: Bool { isEnabled(.standard) }
    static func set(_ on: Bool, defaults d: UserDefaults = .standard) { d.set(on, forKey: key) }
}

/// What the user has configured for the preview, independent of race mode.
struct UserPreviewSettings: Equatable {
    var stabilize = false
    var previewLUT = false
    var colorAdjust = false
    var osd = false
    var grid = false
    var miniWindow = false
}

/// The preview pipeline that is actually in effect. Pure: race mode switches off everything that
/// costs time or main-thread work on the way to the screen.
struct PreviewPipelineConfig: Equatable {
    var stabilizer: Bool
    var previewLUT: Bool
    var colorFilters: Bool
    var osdOverlay: Bool
    var gridOverlay: Bool
    var miniWindow: Bool
    /// Decoder runs with power-efficiency hints off (applied live, no decoder re-creation).
    var lowLatencyDecoder: Bool
    var badge: Bool

    static func resolve(raceMode: Bool, user: UserPreviewSettings) -> PreviewPipelineConfig {
        PreviewPipelineConfig(
            stabilizer: user.stabilize && !raceMode,
            previewLUT: user.previewLUT && !raceMode,
            colorFilters: (user.colorAdjust || user.previewLUT) && !raceMode,
            osdOverlay: user.osd && !raceMode,
            gridOverlay: user.grid && !raceMode,
            miniWindow: user.miniWindow && !raceMode,
            lowLatencyDecoder: raceMode,
            badge: raceMode)
    }
}

#if canImport(AppKit)
extension UserPreviewSettings {
    static var current: UserPreviewSettings {
        let d = UserDefaults.standard
        return UserPreviewSettings(
            stabilize: StabilizerPrefs.enabled,
            previewLUT: LookPrefs.applyPreview && !LookPrefs.name.isEmpty,
            colorAdjust: FramingPrefs.brightness != 0 || FramingPrefs.contrast != 1 || FramingPrefs.saturation != 1,
            osd: d.bool(forKey: OSDPrefs.enabledKey),
            grid: FramingPrefs.grid != .off,
            miniWindow: d.bool(forKey: MiniWindowPrefs.enabledKey))
    }
}

extension PreviewPipelineConfig {
    static var current: PreviewPipelineConfig { resolve(raceMode: RaceModePrefs.enabled, user: .current) }
}

/// Applies race mode live. Most of it is read on the fly (layout, overlays, stabilizer); this only
/// pushes the decoder properties and re-syncs the mini window when the value changes.
final class RaceModeController {
    static let shared = RaceModeController()
    private var sessions: () -> [GogglesSession] = { [] }
    private var applied = false
    private var observer: NSObjectProtocol?

    func install(sessions: @escaping () -> [GogglesSession]) {
        self.sessions = sessions
        applied = RaceModePrefs.enabled
        // The Settings toggle writes UserDefaults directly, so watch defaults rather than a call path.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
        reconcile(force: true)
    }

    var isOn: Bool { RaceModePrefs.enabled }
    func set(_ on: Bool) { RaceModePrefs.set(on); reconcile() }
    func toggle() { set(!isOn) }

    /// Called on main. Cheap when nothing changed (runs on every UserDefaults change).
    private func reconcile(force: Bool = false) {
        let on = RaceModePrefs.enabled
        guard force || on != applied else { return }
        applied = on
        sessions().forEach { $0.decodeSession.applyRaceMode(on) }
        MiniWindowController.shared.refresh()
        NotificationCenter.default.post(name: .gogglesRaceModeChanged, object: nil)
    }
}
#endif

#if canImport(SwiftUI)
/// "RACE" badge in the video window while race mode is active.
struct RaceBadge: View {
    @AppStorage(RaceModePrefs.key) private var race = false

    var body: some View {
        if race {
            Text("RACE")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityLabel("Race mode on")
        }
    }
}

struct RaceModeSettingsSection: View {
    @AppStorage(RaceModePrefs.key) private var race = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Race mode").font(.headline)
            Toggle("Lowest-latency preview", isOn: $race)
            Text("One switch for flying: bypasses stabilization, drops the preview LUT and colour adjustments, hides the stats overlay, grid and mini window, and runs the decoder without power-saving hints. Takes effect immediately, no reconnect. Recording and streaming keep working if you start them. Stabilized frames are not recorded or streamed while it is on. Orientation, crop and zoom stay as set.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
