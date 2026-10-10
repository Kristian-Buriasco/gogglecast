import Foundation

// Export and import of the user-facing preferences as one JSON file.
//
// Only keys listed in `SettingsBackup.specs` are ever written or read. Anything that is a secret
// (stream keys, passphrases, tokens, webhook URLs), a personal identifier (goggles serials and
// profiles), a local path (recording folder, hook scripts, library paths, logo file) or a window frame is
// deliberately absent. Switches that open the app to the network or to other programs (web viewer,
// automation, automatic update install) are absent too, so a file from someone else cannot turn them on.

enum SettingsBackup {
    static let formatVersion = 1

    enum Kind {
        case bool
        case int(ClosedRange<Int>)
        case double(ClosedRange<Double>)
        case oneOf([Int])
        case string(Set<String>)
        /// Free text of at most this many characters (no control characters).
        case text(Int)
    }

    struct Spec {
        let key: String
        let kind: Kind
    }

    private static func b(_ k: String) -> Spec { Spec(key: k, kind: .bool) }
    private static func i(_ k: String, _ r: ClosedRange<Int>) -> Spec { Spec(key: k, kind: .int(r)) }
    private static func d(_ k: String, _ r: ClosedRange<Double>) -> Spec { Spec(key: k, kind: .double(r)) }
    private static func s(_ k: String, _ v: [String]) -> Spec { Spec(key: k, kind: .string(Set(v))) }

    private static var zoom: ClosedRange<Double> {
        Double(FramingGeometry.zoomRange.lowerBound)...Double(FramingGeometry.zoomRange.upperBound)
    }
    private static let aspects = FramingAspect.allCases.map(\.rawValue)

    /// The allowlist. Order is irrelevant; the file is written with sorted keys.
    static let specs: [Spec] = {
        var out: [Spec] = [
            // Preview framing and colour
            s(FramingPrefs.aspectKey, aspects), d(FramingPrefs.zoomKey, zoom),
            d(FramingPrefs.panXKey, -1...1), d(FramingPrefs.panYKey, -1...1),
            s(FramingPrefs.gridKey, FramingGrid.allCases.map(\.rawValue)),
            d(FramingPrefs.brightnessKey, -1...1), d(FramingPrefs.contrastKey, 0...4), d(FramingPrefs.saturationKey, 0...4),
            // Output framing
            b(OutputFramingPrefs.enabledKey), s(OutputFramingPrefs.aspectKey, aspects),
            d(OutputFramingPrefs.zoomKey, zoom), d(OutputFramingPrefs.panXKey, -1...1), d(OutputFramingPrefs.panYKey, -1...1),
            // Colour look (name only, never a path)
            .init(key: LookPrefs.nameKey, kind: .text(120)), d(LookPrefs.intensityKey, 0...1),
            b(LookPrefs.previewKey), b(LookPrefs.outputKey),
            // Stabilizer, re-encoder, race mode
            b(StabilizerPrefs.enabledKey), d(StabilizerPrefs.strengthKey, 0...1),
            b(ReencodePrefs.enabledKey), i(ReencodePrefs.bitrateKey, ReencodePrefs.bitrateRange),
            b(ReencodePrefs.halfRateKey), b(FeedPortPrefs.perFeedKey),
            b(RaceModePrefs.key),
            // Recording (no folder)
            s(RecordingPrefs.containerKey, RecordingPrefs.Container.allCases.map(\.rawValue)),
            .init(key: RecordingPrefs.prefixKey, kind: .text(60)), b(RecordingPrefs.autoStartKey),
            i(RecordingExtras.splitMinutesKey, 0...120), i(RecordingExtras.splitMegabytesKey, 0...100_000),
            i(RecordingExtras.loopKeepMinutesKey, 0...1_440), i(RecordingExtras.autoDeleteDaysKey, 0...3_650),
            b(AutoMarkerPrefs.enabledKey), b(AutoMarkerPrefs.signalKey), b(AutoMarkerPrefs.batteryKey),
            b(AutoMarkerPrefs.capturesKey), b(AutoMarkerPrefs.raceKey),
            // Burn-in (no logo file)
            s(BurnInPrefs.cornerKey, BurnInCorner.allCases.map(\.rawValue)),
            i(BurnInPrefs.scaleKey, BurnInPrefs.scaleRange), i(BurnInPrefs.opacityKey, BurnInPrefs.opacityRange),
            b(BurnInPrefs.showTimeKey), b(BurnInPrefs.showStatsKey),
            s(BurnInPrefs.codecKey, BurnInCodec.allCases.map(\.rawValue)),
            i(BurnInPrefs.bitrateKey, BurnInPrefs.bitrateRange),
            s(BurnInPrefs.containerKey, RecordingPrefs.Container.allCases.map(\.rawValue)),
            // Instant replay
            b(ReplayPrefs.enabledKey), i(ReplayPrefs.secondsKey, ReplayPrefs.secondsRange),
            // On-screen display
            b(OSDPrefs.enabledKey), b(OSDPrefs.showFpsKey), b(OSDPrefs.showBitrateKey), b(OSDPrefs.showResolutionKey),
            b(OSDPrefs.showDropsKey), b(OSDPrefs.showLatencyKey), b(OSDPrefs.showBatteryKey),
            // Network stream (UDP host and port only)
            .init(key: NetStreamPrefs.hostKey, kind: .text(253)), i(NetStreamPrefs.portKey, 1...65535),
            b(NetStreamPrefs.autoStartKey), b(SRTPrefs.autoStartKey),
            // Windows and orientation
            b(MiniWindowPrefs.enabledKey), b(CaptureWindowPrefs.enabledKey), b(CaptureWindowPrefs.onTopKey),
            Spec(key: OrientationPrefs.rotationKey, kind: .oneOf([0, 90, 180, 270])), b(OrientationPrefs.flipHKey), b(OrientationPrefs.flipVKey),
            b(OrientationPrefs.hideCursorKey), b(MenuBarPrefs.showKey),
            // Signal alert
            b(SignalAlertPrefs.enabledKey), i(SignalAlertPrefs.thresholdKey, SignalAlertPrefs.thresholdRange),
            b(SignalAlertPrefs.soundEnabledKey), s(SignalAlertPrefs.soundNameKey, SignalAlertPrefs.soundChoices),
            // Updates (check only), session log, hooks threshold, hotkeys
            b(UpdatePrefs.enabledKey), b(SessionLogPrefs.enabledKey), i(SessionLogPrefs.retentionDaysKey, SessionLogPrefs.retentionRange),
            i(EventHookConfig.batteryKey, 1...100), b(GlobalHotkeyPrefs.enabledKey),
        ]
        for a in GlobalHotkeyAction.allCases {
            out.append(i(a.keyCodeKey, 0...255))
            out.append(i(a.modifiersKey, 0...0xFFFF))
        }
        return out
    }()

    static let allowedKeys: Set<String> = Set(specs.map(\.key))
    private static let specByKey: [String: Spec] = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0) })

    // MARK: Validation

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A clean value for `spec`, clamped into range, or nil when the type is wrong.
    static func validated(_ raw: Any, for spec: Spec) -> Any? {
        switch spec.kind {
        case .bool:
            return isBool(raw) ? (raw as? NSNumber)?.boolValue : nil
        case .int(let r):
            guard !isBool(raw), let n = raw as? NSNumber else { return nil }
            let v = n.doubleValue
            guard v.isFinite, v.rounded() == v, abs(v) < 1e12 else { return nil }
            return min(max(Int(v), r.lowerBound), r.upperBound)
        case .double(let r):
            guard !isBool(raw), let n = raw as? NSNumber, n.doubleValue.isFinite else { return nil }
            return min(max(n.doubleValue, r.lowerBound), r.upperBound)
        case .oneOf(let choices):
            guard !isBool(raw), let n = raw as? NSNumber, choices.contains(n.intValue), Double(n.intValue) == n.doubleValue else { return nil }
            return n.intValue
        case .string(let allowed):
            guard let t = raw as? String, allowed.contains(t) else { return nil }
            return t
        case .text(let maxLength):
            guard let t = raw as? String, t.count <= maxLength,
                  !t.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return t
        }
    }

    // MARK: Export

    /// Only keys the user has actually set; unset keys keep following the app defaults.
    static func snapshot(_ defaults: UserDefaults = .standard) -> [String: Any] {
        var out: [String: Any] = [:]
        for spec in specs {
            guard let raw = defaults.object(forKey: spec.key), let v = validated(raw, for: spec) else { continue }
            out[spec.key] = v
        }
        return out
    }

    static func encode(defaults: UserDefaults = .standard, appVersion: String) throws -> Data {
        let doc: [String: Any] = ["format": formatVersion, "app": appVersion, "settings": snapshot(defaults)]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Import

    struct Plan {
        /// Validated values to write, keyed by preference key.
        var values: [String: Any] = [:]
        /// Keys whose stored value would change.
        var changed: [String] = []
        /// Allowlisted keys with a value of the wrong type.
        var rejected: [String] = []
        /// Keys in the file that are not on the allowlist.
        var ignored: [String] = []
        var count: Int { changed.count }
    }

    enum ImportError: Error, Equatable {
        case notSettingsFile
        case newerFormat(Int)

        var message: String {
            switch self {
            case .notSettingsFile: return L("This is not a GogglesView settings file.")
            case .newerFormat: return L("This file was made by a newer version of GogglesView. Update the app and try again.")
            }
        }
    }

    static func plan(from data: Data, defaults: UserDefaults = .standard) throws -> Plan {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = (root["format"] as? NSNumber)?.intValue,
              let settings = root["settings"] as? [String: Any] else { throw ImportError.notSettingsFile }
        guard format <= formatVersion else { throw ImportError.newerFormat(format) }
        var plan = Plan()
        for key in settings.keys.sorted() {
            guard let spec = specByKey[key] else { plan.ignored.append(key); continue }
            guard let v = validated(settings[key]!, for: spec) else { plan.rejected.append(key); continue }
            plan.values[key] = v
            if !same(defaults.object(forKey: key), v) { plan.changed.append(key) }
        }
        return plan
    }

    private static func same(_ stored: Any?, _ new: Any) -> Bool {
        guard let stored else { return false }
        if let a = stored as? String, let b = new as? String { return a == b }
        if let a = stored as? NSNumber, let b = new as? NSNumber, isBool(a) == isBool(b) { return a.doubleValue == b.doubleValue }
        return false
    }

    /// Writes the values that differ. Returns how many settings were applied.
    @discardableResult
    static func apply(_ plan: Plan, defaults: UserDefaults = .standard) -> Int {
        for key in plan.changed { defaults.set(plan.values[key], forKey: key) }
        return plan.changed.count
    }

    static func summary(_ plan: Plan, applied: Bool) -> String {
        let n = plan.changed.count
        var text: String
        if applied {
            text = n == 1 ? L("Applied 1 setting.") : L("Applied %lld settings.", n)
        } else {
            text = n == 1 ? L("1 setting will change.") : L("%lld settings will change.", n)
        }
        if !plan.rejected.isEmpty { text += " " + L("Skipped %lld with invalid values.", plan.rejected.count) }
        if !plan.ignored.isEmpty { text += " " + L("Ignored %lld unknown.", plan.ignored.count) }
        return text
    }

    static var reopenNote: String { L("Some settings apply after you reopen the goggles windows.") }
    static let suggestedFileName = "GogglesView-settings.json"
}

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsBackupSection: View {
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Back up settings").font(.headline)
            HStack {
                Button("Export…") { export() }
                    .accessibilityLabel("Export settings to a file")
                    .accessibilityIdentifier("exportSettingsButton")
                Button("Import…") { importFile() }
                    .accessibilityLabel("Import settings from a file")
                    .accessibilityIdentifier("importSettingsButton")
            }
            Text("Saves your preferences to a file you can restore later or copy to another Mac. Stream keys, passwords, folders and goggles details are never included.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SettingsBackup.suggestedFileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsBackup.encode(appVersion: UpdateChecker.currentVersion)
            try data.write(to: url, options: .atomic)
            message = L("Saved settings to %@.", url.lastPathComponent)
        } catch {
            message = L("Could not save the file: %@", error.localizedDescription)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let plan = try SettingsBackup.plan(from: data)
            guard plan.count > 0 else { message = L("Nothing to change.") + " " + SettingsBackup.summary(plan, applied: true); return }
            let alert = NSAlert()
            alert.messageText = plan.count == 1 ? L("Import 1 setting?") : L("Import %lld settings?", plan.count)
            alert.informativeText = SettingsBackup.summary(plan, applied: false) + " " + SettingsBackup.reopenNote
            alert.addButton(withTitle: L("Import"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SettingsBackup.apply(plan)
            message = SettingsBackup.summary(plan, applied: true) + " " + SettingsBackup.reopenNote
        } catch let e as SettingsBackup.ImportError {
            message = e.message
        } catch {
            message = L("Could not read the file: %@", error.localizedDescription)
        }
    }
}
#endif
