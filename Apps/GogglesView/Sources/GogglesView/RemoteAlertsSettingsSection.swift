import SwiftUI

/// Settings card "Remote alerts (ntfy)". Self-contained: mounted once in the Advanced tab.
struct RemoteAlertsSettingsSection: View {
    @AppStorage(AlertPrefs.serverKey) private var server = ""
    @AppStorage(AlertPrefs.topicKey) private var topic = ""
    @AppStorage(AlertPrefs.awayKey) private var away = false
    @AppStorage(AlertPrefs.repeatKey) private var repeatMinutes = 2
    @AppStorage(AlertPrefs.heartbeatKey) private var heartbeat = ""
    @KeychainSecret(AlertPrefs.tokenKey) private var token
    @FocusState private var tokenFocused: Bool
    @ObservedObject private var center = AlertCenter.shared

    private var configured: Bool { NtfyRequest.url(server: server, topic: topic) != nil }

    var body: some View {
        SettingsGroup("Remote alerts (ntfy)",
                      footer: "Nothing is sent until Away mode is on. Each problem is sent once, then again every few minutes until it clears, followed by a recovery message. Messages use the crew feed names, never a serial number. The token is kept in the macOS Keychain. The heartbeat pings the URL every 30 s while Away mode is on, so an external monitor can alert you if this Mac goes silent.") {
            SettingsToggleRow("Away mode: send alerts to my phone", isOn: $away, accessibilityName: "Away mode")
                .disabled(!configured)
            SettingsRow("Server") {
                TextField("Server", text: $server, prompt: Text(verbatim: "https://ntfy.example.com"))
                    .labelsHidden().settingsField().accessibilityLabel("ntfy server")
            }
            SettingsRow("Topic") {
                TextField("Topic", text: $topic, prompt: Text(verbatim: "gogglesview"))
                    .labelsHidden().settingsField().accessibilityLabel("ntfy topic")
            }
            SettingsRow("Access token (optional)") {
                SettingsSecretField(title: "Access token (optional)", text: $token, onReveal: { _token.load() }) // Keychain read waits for the click
                    .accessibilityLabel("ntfy access token")
            }
            if !configured && (!server.isEmpty || !topic.isEmpty) {
                SettingsRow("Status") {
                    Text("The server must start with http:// or https://. The topic may use letters, digits, - and _.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsRow("Send test") {
                HStack {
                    Button("Send test") { center.sendTests() }
                        .disabled(!configured)
                        .accessibilityLabel("Send test alerts")
                    Text(center.lastSend.map { $0.ok ? L("Last send: ok at %@", Self.time($0)) : L("Last send: failed at %@", Self.time($0)) } ?? L("Not sent yet"))
                        .font(.caption).foregroundStyle(center.lastSend?.ok == false ? Color.orange : Color.secondary)
                }
            }
            SettingsRow("Repeat") {
                Stepper(repeatMinutes == 0 ? L("Do not repeat while still failing") : L("Repeat every %lld min while still failing (up to 10 times)", repeatMinutes),
                        value: $repeatMinutes, in: AlertPrefs.repeatRange)
                    .accessibilityLabel("Repeat interval in minutes")
            }
            ForEach(AlertKind.allCases) { AlertKindRow(kind: $0) }
            SettingsRow("Heartbeat URL (optional)") {
                TextField("Heartbeat URL (optional)", text: $heartbeat, prompt: Text(verbatim: "https://hc-ping.com/your-uuid"))
                    .labelsHidden().settingsField().accessibilityLabel("Heartbeat URL")
            }
            if !heartbeat.isEmpty {
                SettingsRow("Status") {
                    Text(center.lastPing.map { $0.ok ? L("Heartbeat: ok at %@", Self.time($0)) : L("Heartbeat: failed at %@", Self.time($0)) } ?? L("Not sent yet"))
                        .font(.caption).foregroundStyle(center.lastPing?.ok == false ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private static func time(_ s: AlertCenter.Status) -> String { s.at.formatted(date: .omitted, time: .shortened) }
}

private struct AlertKindRow: View {
    let kind: AlertKind
    @AppStorage private var enabled: Bool
    @AppStorage private var delay: Int
    @AppStorage private var priority: Int

    init(kind: AlertKind) {
        self.kind = kind
        _enabled = AppStorage(wrappedValue: true, AlertPrefs.enabledKey(kind))
        _delay = AppStorage(wrappedValue: kind.defaultDelay, AlertPrefs.delayKey(kind))
        _priority = AppStorage(wrappedValue: kind.defaultPriority, AlertPrefs.priorityKey(kind))
    }

    var body: some View {
        SettingsRow(LocalizedStringKey(kind.title)) {
            Toggle(kind.title, isOn: $enabled).labelsHidden()
                .accessibilityLabel(kind.title)
                .accessibilityValue(AccessibilityLabels.onOff(enabled))
            Stepper(L("after %lld s", delay), value: $delay, in: 0...600, step: 5)
                .disabled(!enabled)
                .accessibilityLabel(L("%@: delay in seconds", kind.title))
            Picker("Priority", selection: $priority) {
                Text("Min").tag(1); Text("Low").tag(2); Text("Default").tag(3); Text("High").tag(4); Text("Urgent").tag(5)
            }
            .labelsHidden().frame(width: 90).disabled(!enabled)
            .accessibilityLabel(L("%@: priority", kind.title))
        }
    }
}
