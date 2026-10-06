import SwiftUI

/// Built-in settings bundles. Each maps UserDefaults keys to a value; `nil` means
/// "remove the key" (falls back to the default defined where the pref is read).
enum SettingsPreset: String, CaseIterable, Identifiable {
    case streaming = "Streaming", recording = "Recording", minimal = "Minimal"
    var id: String { rawValue }

    var summary: String {
        switch self {
        case .streaming: return "Stats overlay on, network stream auto-starts, no recording/replay."
        case .recording: return "Auto-record on connect, instant replay (60 s), clean video."
        case .minimal: return "Everything optional off; framing reset."
        }
    }

    /// Keys every preset sets, so applying one fully replaces the previous.
    static let managedKeys: [String] = [
        OSDPrefs.enabledKey, OSDPrefs.showFpsKey, OSDPrefs.showBitrateKey, OSDPrefs.showResolutionKey,
        OSDPrefs.showDropsKey, OSDPrefs.showLatencyKey, OSDPrefs.showBatteryKey,
        RecordingPrefs.autoStartKey, RecordingPrefs.containerKey,
        NetStreamPrefs.autoStartKey,
        ReplayPrefs.enabledKey, ReplayPrefs.secondsKey,
        FramingPrefs.aspectKey, FramingPrefs.zoomKey, FramingPrefs.panXKey, FramingPrefs.panYKey,
        FramingPrefs.gridKey, FramingPrefs.brightnessKey, FramingPrefs.contrastKey, FramingPrefs.saturationKey,
        OutputFramingPrefs.enabledKey, OutputFramingPrefs.aspectKey, OutputFramingPrefs.zoomKey,
        OutputFramingPrefs.panXKey, OutputFramingPrefs.panYKey,
    ]
    // Orientation (rotation/flip) is mount-specific, so presets deliberately leave it alone;
    // host/port/folder/prefix are user data, not mode.

    var values: [String: Any?] {
        // Start from "defaults" (nil) for every managed key, then override.
        var v: [String: Any?] = Dictionary(uniqueKeysWithValues: Self.managedKeys.map { ($0, nil as Any?) })
        switch self {
        case .streaming:
            v[OSDPrefs.enabledKey] = true
            v[OSDPrefs.showDropsKey] = true
            v[NetStreamPrefs.autoStartKey] = true
            v[ReplayPrefs.enabledKey] = false
        case .recording:
            v[OSDPrefs.enabledKey] = false
            v[RecordingPrefs.autoStartKey] = true
            v[RecordingPrefs.containerKey] = RecordingPrefs.Container.mov.rawValue
            v[ReplayPrefs.enabledKey] = true
            v[ReplayPrefs.secondsKey] = 60
        case .minimal:
            v[OSDPrefs.enabledKey] = false
            v[RecordingPrefs.autoStartKey] = false
            v[NetStreamPrefs.autoStartKey] = false
            v[ReplayPrefs.enabledKey] = false
        }
        return v
    }

    func apply(to d: UserDefaults = .standard) {
        for (k, v) in values { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
    }

    static func resetAll(in d: UserDefaults = .standard) {
        managedKeys.forEach { d.removeObject(forKey: $0) }
    }
}

struct PresetsSettingsSection: View {
    @State private var selection: SettingsPreset = .minimal
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.headline)
            HStack {
                Picker("", selection: $selection) {
                    ForEach(SettingsPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("Apply") { selection.apply(); message = "Applied \(selection.rawValue)." }
                Button("Reset all to defaults") { SettingsPreset.resetAll(); message = "Reset to defaults." }
            }
            Text(selection.summary).font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
