import SwiftUI
import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let gogglesToggleRecording = Notification.Name("GogglesToggleRecording")
    static let gogglesScreenshot = Notification.Name("GogglesScreenshot")
    static let gogglesSaveReplay = Notification.Name("GogglesSaveReplay")
    static let gogglesCopyFrame = Notification.Name("GogglesCopyFrame")
}

/// Multi-window targeting: a global hotkey acts on ONE goggles window (the
/// active one) rather than every open window. The notification's `object`
/// is that window's `DecodeSession`; `nil` means "every listener" (no
/// resolver installed, e.g. dev harnesses).
enum GlobalHotkeyRouting {
    static var targetProvider: (() -> AnyObject?)?

    static func shouldHandle(_ notification: Notification, session: AnyObject) -> Bool {
        guard let target = notification.object else { return true }
        return (target as AnyObject) === session
    }
}

/// A key combo. `carbonModifiers` uses Carbon's cmdKey/optionKey/controlKey/shiftKey bits.
struct HotkeyCombo: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers; self.display = display
    }
    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.init(keyCode: keyCode, carbonModifiers: carbonModifiers,
                  display: Self.displayString(keyCode: keyCode, carbonModifiers: carbonModifiers))
    }

    /// Modifier glyphs in the standard macOS order (⌃⌥⇧⌘) followed by the key name.
    static func displayString(keyCode: UInt32, carbonModifiers m: UInt32) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    static func keyName(_ code: UInt32) -> String { keyNames[Int(code)] ?? "Key\(code)" }
}

enum GlobalHotkeyAction: UInt32, CaseIterable {
    case toggleRecording = 1, screenshot, saveReplay

    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    var defaultCombo: HotkeyCombo {
        switch self {
        case .toggleRecording: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: Self.defaultModifiers)
        case .screenshot: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: Self.defaultModifiers)
        case .saveReplay: return HotkeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: Self.defaultModifiers)
        }
    }
    /// User override from UserDefaults, else the default.
    var combo: HotkeyCombo { GlobalHotkeyBindings.combo(for: self) }
    var keyCodeKey: String { "globalHotkey.\(rawValue).keyCode" }
    var modifiersKey: String { "globalHotkey.\(rawValue).modifiers" }
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

enum GlobalHotkeyBindings {
    static func combo(for a: GlobalHotkeyAction, defaults d: UserDefaults = .standard) -> HotkeyCombo {
        guard d.object(forKey: a.keyCodeKey) != nil, d.object(forKey: a.modifiersKey) != nil else { return a.defaultCombo }
        return HotkeyCombo(keyCode: UInt32(max(0, d.integer(forKey: a.keyCodeKey))),
                           carbonModifiers: UInt32(max(0, d.integer(forKey: a.modifiersKey))))
    }
    static func set(_ c: HotkeyCombo, for a: GlobalHotkeyAction, defaults d: UserDefaults = .standard) {
        d.set(Int(c.keyCode), forKey: a.keyCodeKey)
        d.set(Int(c.carbonModifiers), forKey: a.modifiersKey)
    }
    static func reset(_ a: GlobalHotkeyAction, defaults d: UserDefaults = .standard) {
        d.removeObject(forKey: a.keyCodeKey); d.removeObject(forKey: a.modifiersKey)
    }
    /// The other action already using `candidate` (same key + modifiers), if any.
    static func conflict(for action: GlobalHotkeyAction, candidate: HotkeyCombo,
                         assignments: [GlobalHotkeyAction: HotkeyCombo]) -> GlobalHotkeyAction? {
        GlobalHotkeyAction.allCases.first { other in
            guard other != action, let c = assignments[other] else { return false }
            return c.keyCode == candidate.keyCode && c.carbonModifiers == candidate.carbonModifiers
        }
    }
    /// Carbon modifier bits for an AppKit flag set (only the four hotkey-relevant modifiers).
    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
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
                NotificationCenter.default.post(name: action.notification, object: GlobalHotkeyRouting.targetProvider?())
            }
            return noErr
        }, 1, &spec, nil, &handler)
        var failed: [String] = []
        for action in GlobalHotkeyAction.allCases {
            let combo = action.combo
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x47564857), id: action.rawValue) // 'GVHW'
            let st = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(combo.display) }
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

/// Captures the next key press (with at least one modifier) while recording. Escape cancels.
struct KeyRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (HotkeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderNSView { RecorderNSView() }
    func updateNSView(_ v: RecorderNSView, context: Context) {
        v.onCapture = { combo in onCapture(combo); isRecording = false }
        v.onCancel = { isRecording = false }
        v.recording = isRecording
        if isRecording { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }

    final class RecorderNSView: NSView {
        var recording = false
        var onCapture: ((HotkeyCombo) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        private func handle(_ e: NSEvent) -> Bool {
            guard recording else { return false }
            if e.keyCode == UInt16(kVK_Escape) { onCancel?(); return true }
            let mods = GlobalHotkeyBindings.carbonModifiers(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return true } // a modifier is required
            onCapture?(HotkeyCombo(keyCode: UInt32(e.keyCode), carbonModifiers: mods))
            return true
        }
        override func keyDown(with e: NSEvent) { if !handle(e) { super.keyDown(with: e) } }
        // ⌘-combos are offered to the menu bar first; claim them while recording.
        override func performKeyEquivalent(with e: NSEvent) -> Bool { handle(e) }
        override func resignFirstResponder() -> Bool {
            if recording { onCancel?() }
            return super.resignFirstResponder()
        }
    }
}

/// Settings toggle + rebindable combos.
struct GlobalHotkeysSettingsSection: View {
    @AppStorage(GlobalHotkeyPrefs.enabledKey) private var enabled = false
    @ObservedObject private var hotkeys = GlobalHotkeys.shared
    @State private var combos: [GlobalHotkeyAction: HotkeyCombo] = [:]
    @State private var recording: GlobalHotkeyAction?
    @State private var message: String?

    private func reload() {
        combos = Dictionary(uniqueKeysWithValues: GlobalHotkeyAction.allCases.map { ($0, $0.combo) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global hotkeys").font(.headline)
            Toggle("Work while another app is focused", isOn: $enabled)
            ForEach(GlobalHotkeyAction.allCases, id: \.rawValue) { a in
                HStack {
                    Text(a.title)
                    Spacer()
                    Button(recording == a ? "Press keys… (esc cancels)" : (combos[a]?.display ?? a.combo.display)) {
                        message = nil
                        recording = recording == a ? nil : a
                    }
                    .font(.body.monospaced())
                    .background(KeyRecorderView(isRecording: Binding(
                        get: { recording == a },
                        set: { if !$0, recording == a { recording = nil } }
                    )) { combo in
                        if let other = GlobalHotkeyBindings.conflict(for: a, candidate: combo, assignments: combos) {
                            message = "\(combo.display) is already used by \"\(other.title)\""
                        } else {
                            GlobalHotkeyBindings.set(combo, for: a)
                            message = nil
                            reload()
                            hotkeys.apply()
                        }
                    }.frame(width: 0, height: 0))
                }
                .font(.caption)
            }
            Button("Reset to defaults") {
                GlobalHotkeyAction.allCases.forEach { GlobalHotkeyBindings.reset($0) }
                message = nil
                reload()
                hotkeys.apply()
            }
            .controlSize(.small)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            if let err = hotkeys.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
        .onChange(of: enabled) { _, _ in hotkeys.apply() }
    }
}
