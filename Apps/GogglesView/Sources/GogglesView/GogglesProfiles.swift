import Foundation

/// A UserDefaults-storable scalar, Codable so a settings snapshot survives JSON.
enum ProfileValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String)

    init?(_ any: Any) {
        if let n = any as? NSNumber {
            // NSNumber bridges Bool/Int/Double indistinguishably; check the CF type first.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e15 { self = .int(n.intValue) }
            else { self = .double(n.doubleValue) }
        } else if let s = any as? String { self = .string(s) }
        else { return nil }
    }

    var any: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        }
    }
}

struct GogglesProfile: Codable, Equatable {
    var nickname: String = ""
    /// Snapshot of `ProfileStore.managedKeys`; keys absent from the snapshot were at their defaults.
    var settings: [String: ProfileValue] = [:]
    var hasSnapshot = false
    var autoApply = false
}

final class ProfileStore {
    static let shared = ProfileStore()
    static let storageKey = "goggleProfiles"

    /// Reuses the preset key list; adds orientation, which presets deliberately skip
    /// but which is per-goggles mount state.
    static var managedKeys: [String] {
        SettingsPreset.managedKeys + [OrientationPrefs.rotationKey, OrientationPrefs.flipHKey, OrientationPrefs.flipVKey]
    }

    private let store: UserDefaults
    private let settings: UserDefaults
    init(store: UserDefaults = .standard, settings: UserDefaults = .standard) {
        self.store = store
        self.settings = settings
    }

    // MARK: pure functions

    static func snapshot(from d: UserDefaults, keys: [String] = managedKeys) -> [String: ProfileValue] {
        var out: [String: ProfileValue] = [:]
        for k in keys { if let v = d.object(forKey: k).flatMap(ProfileValue.init) { out[k] = v } }
        return out
    }

    /// Keys missing from the snapshot are removed so the profile fully replaces current settings.
    static func apply(_ snapshot: [String: ProfileValue], to d: UserDefaults, keys: [String] = managedKeys) {
        for k in keys {
            if let v = snapshot[k] { d.set(v.any, forKey: k) } else { d.removeObject(forKey: k) }
        }
    }

    // MARK: storage

    var all: [String: GogglesProfile] {
        get {
            guard let data = store.data(forKey: Self.storageKey) else { return [:] }
            return (try? JSONDecoder().decode([String: GogglesProfile].self, from: data)) ?? [:]
        }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: Self.storageKey) }
    }

    func profile(for serial: String) -> GogglesProfile? { all[serial] }

    func nickname(for serial: String?) -> String? {
        guard let serial, let n = all[serial]?.nickname.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        return n
    }

    func setNickname(_ name: String, for serial: String) {
        var a = all; a[serial, default: GogglesProfile()].nickname = name; all = a
    }

    func setAutoApply(_ on: Bool, for serial: String) {
        var a = all; a[serial, default: GogglesProfile()].autoApply = on; all = a
    }

    func saveCurrentSettings(for serial: String) {
        var a = all
        a[serial, default: GogglesProfile()].settings = Self.snapshot(from: settings)
        a[serial]?.hasSnapshot = true
        all = a
    }

    /// Applies the saved snapshot if the profile has one and auto-apply is on. Returns whether it applied.
    @discardableResult
    func applyIfEnabled(serial: String?) -> Bool {
        guard let serial, let p = all[serial], p.autoApply, p.hasSnapshot else { return false }
        Self.apply(p.settings, to: settings)
        return true
    }
}

/// Picker/identity label: "Nickname (S/N X)" when a nickname exists, else nil.
func profileDisplayName(nickname: String?, serial: String?) -> String? {
    guard let nickname, !nickname.isEmpty else { return nil }
    return serial.map { "\(nickname) (\($0))" } ?? nickname
}

#if canImport(SwiftUI)
import SwiftUI

/// General-tab section. `deviceSerial` is `coordinator.deviceInfo?.serial` (nil when no device is selected).
struct ProfileSettingsSection: View {
    let deviceSerial: String?
    @State private var nickname = ""
    @State private var autoApply = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Goggles profile").font(.headline)
            if let serial = deviceSerial {
                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { ProfileStore.shared.setNickname(nickname, for: serial) }
                    .onChange(of: nickname) { ProfileStore.shared.setNickname($0, for: serial) }
                    .accessibilityLabel("Nickname for goggles \(serial)")
                    .accessibilityIdentifier("profileNicknameField")
                HStack {
                    Button("Save current settings to this goggles") {
                        ProfileStore.shared.saveCurrentSettings(for: serial)
                        message = "Saved."
                    }
                    .accessibilityIdentifier("profileSaveButton")
                    Toggle("Auto-apply on connect", isOn: $autoApply)
                        .onChange(of: autoApply) { ProfileStore.shared.setAutoApply($0, for: serial) }
                        .accessibilityIdentifier("profileAutoApplyToggle")
                }
                Text("S/N \(serial)").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Connect goggles to name them and save settings per device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: deviceSerial) { _ in load() }
    }

    private func load() {
        message = nil
        guard let s = deviceSerial else { return }
        nickname = ProfileStore.shared.profile(for: s)?.nickname ?? ""
        autoApply = ProfileStore.shared.profile(for: s)?.autoApply ?? false
    }
}
#endif
