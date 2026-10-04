import SwiftUI
import AppKit

/// Settings > Advanced: the "Allow automation" switch for the
/// `gogglesview://` URL scheme and the AppleScript suite (see Automation.swift,
/// docs/automation.md). Carries its own leading divider so SettingsView only
/// needs one line.
struct AutomationSettingsSection: View {
    @AppStorage(AutomationPrefs.enabledKey) private var enabled = true
    @State private var example = AutomationURLParser.exampleURL("record/toggle")
    @State private var copied = false

    var body: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Automation").font(.headline)
            Toggle("Allow automation (URL scheme and AppleScript)", isOn: $enabled)
            Text("Lets Shortcuts, Stream Deck, Raycast, `open` and AppleScript start/stop recording, save the replay, take a screenshot, freeze, add a marker, start/stop the UDP stream and show the window. URLs can only trigger these actions -- never files, shell commands or hosts.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $example) {
                    ForEach(AutomationURLParser.examplePaths, id: \.self) { path in
                        Text(AutomationURLParser.exampleURL(path)).tag(AutomationURLParser.exampleURL(path))
                    }
                }
                .labelsHidden()
                .font(.caption.monospaced())
                Button(copied ? "Copied" : "Copy example") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("open \"\(example)\"", forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
            .disabled(!enabled)
            Text("Add ?device=<serial> to target specific goggles. See docs/automation.md.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
