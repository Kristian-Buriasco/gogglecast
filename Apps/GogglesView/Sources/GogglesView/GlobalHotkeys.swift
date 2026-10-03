import SwiftUI
import Carbon.HIToolbox

extension Notification.Name {
    static let gogglesToggleRecording = Notification.Name("GogglesToggleRecording")
    static let gogglesScreenshot = Notification.Name("GogglesScreenshot")
    static let gogglesSaveReplay = Notification.Name("GogglesSaveReplay")
}

/// A fixed key combo. `carbonModifiers` uses Carbon's cmdKey/optionKey/controlKey bits.
struct HotkeyCombo: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String
}

enum GlobalHotkeyAction: UInt32, CaseIterable {
    case toggleRecording = 1, screenshot, saveReplay

    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    var combo: HotkeyCombo {
        switch self {
        case .toggleRecording: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: Self.defaultModifiers, display: "⌃⌥⌘R")
        case .screenshot: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: Self.defaultModifiers, display: "⌃⌥⌘S")
        case .saveReplay: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: Self.defaultModifiers, display: "⌃⌥⌘P")
        }
    }
    var title: String {
        switch self {
        case .toggleRecording: return "Start/stop recording"
        case .screenshot: return "Screenshot"
        case .saveReplay: return "Save instant replay"
        }
    }
    var notification: Notification.Name {
        switch self {
        case .toggleRecording: return .gogglesToggleRecording
        case .screenshot: return .gogglesScreenshot
        case .saveReplay: return .gogglesSaveReplay
        }
    }
}

enum GlobalHotkeyPrefs {
    static let enabledKey = "globalHotkeysEnabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

/// Carbon `RegisterEventHotKey` wrapper: works while another app is focused and
/// needs no Accessibility / Input Monitoring permission.
final class GlobalHotkeys: ObservableObject {
    static let shared = GlobalHotkeys()
    @Published private(set) var lastError: String?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Install or remove hotkeys to match the saved preference.
    func apply() { GlobalHotkeyPrefs.enabled ? install() : uninstall() }

    func install() {
        uninstall()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = GlobalHotkeyAction(rawValue: id.id) {
                NotificationCenter.default.post(name: action.notification, object: nil)
            }
            return noErr
        }, 1, &spec, nil, &handler)
        var failed: [String] = []
        for action in GlobalHotkeyAction.allCases {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x47564857), id: action.rawValue) // 'GVHW'
            let st = RegisterEventHotKey(action.combo.keyCode, action.combo.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(action.combo.display) }
        }
        lastError = failed.isEmpty ? nil : "Could not register \(failed.joined(separator: ", ")) (already in use by another app)"
    }

    func uninstall() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        lastError = nil
    }
}

/// Settings toggle + read-only list of the fixed combos (rebinding is not supported).
struct GlobalHotkeysSettingsSection: View {
    @AppStorage(GlobalHotkeyPrefs.enabledKey) private var enabled = false
    @ObservedObject private var hotkeys = GlobalHotkeys.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global hotkeys").font(.headline)
            Toggle("Work while another app is focused", isOn: $enabled)
            ForEach(GlobalHotkeyAction.allCases, id: \.rawValue) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    Text(a.combo.display).font(.body.monospaced()).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let err = hotkeys.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: enabled) { _, _ in hotkeys.apply() }
    }
}
