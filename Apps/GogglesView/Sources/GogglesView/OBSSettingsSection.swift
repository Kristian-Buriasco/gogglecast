#if canImport(AppKit)
import SwiftUI

/// Settings > Streaming > OBS Studio: opt-in connection and rules.
struct OBSSettingsSection: View {
    @AppStorage(OBSPrefs.enabledKey) private var enabled = false
    @AppStorage(OBSPrefs.hostKey) private var host = OBSPrefs.defaultHost
    @AppStorage(OBSPrefs.portKey) private var port = OBSPrefs.defaultPort
    @KeychainSecret(OBSPrefs.passwordKey) private var password
    @AppStorage(OBSPrefs.recordWithStreamKey) private var recordWithStream = false
    @AppStorage(OBSPrefs.graceSecondsKey) private var grace = OBSPrefs.defaultGraceSeconds
    @AppStorage(OBSPrefs.sceneSwitchKey) private var switchScenes = false
    @AppStorage(OBSPrefs.liveSceneKey) private var liveScene = ""
    @AppStorage(OBSPrefs.lostSceneKey) private var lostScene = ""
    @AppStorage(OBSPrefs.stopWithMineKey) private var stopWithMine = false
    @ObservedObject private var obs = OBSIntegration.shared
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OBS Studio").font(.headline)
            Text("Connect to OBS over its WebSocket server to start recording and switch scenes when your goggles go live. Off by default. GogglesView only talks to the host you enter here.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Connect to OBS", isOn: $enabled)
                .accessibilityLabel("Connect to OBS Studio")
                .accessibilityValue(AccessibilityLabels.onOff(enabled))
            Group {
                HStack {
                    TextField("Host", text: $host, prompt: Text(OBSPrefs.defaultHost))
                        .accessibilityLabel("OBS host")
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .frame(width: 70)
                        .accessibilityLabel("OBS WebSocket port")
                }
                SecureField("Password", text: $password, prompt: Text("Leave empty if OBS has none"))
                    .accessibilityLabel("OBS WebSocket password")
                HStack {
                    Button(testing ? "Testing..." : "Test connection") { runTest() }
                        .disabled(testing)
                        .accessibilityLabel("Test OBS connection")
                    if let testResult { Text(testResult).font(.caption).lineLimit(2) }
                }
                Text("The password is stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Divider().padding(.vertical, 2)
            Group {
                Toggle("Record in OBS while I'm live", isOn: $recordWithStream)
                    .accessibilityValue(AccessibilityLabels.onOff(recordWithStream))
                Stepper("Stop after the signal is lost for \(grace) s", value: $grace, in: OBSPrefs.graceRange, step: 5)
                    .disabled(!recordWithStream)
                    .accessibilityLabel("Stop OBS recording after signal loss")
                    .accessibilityValue(AccessibilityLabels.quantity(grace, unit: "seconds"))
                Toggle("Switch OBS scenes", isOn: $switchScenes)
                    .accessibilityValue(AccessibilityLabels.onOff(switchScenes))
                scenePicker("Scene when live", selection: $liveScene, role: "live")
                scenePicker("Scene when lost", selection: $lostScene, role: "lost")
                Toggle("Stop the OBS recording when I stop mine", isOn: $stopWithMine)
                    .accessibilityValue(AccessibilityLabels.onOff(stopWithMine))
                Text("Only affects a recording GogglesView started in OBS. If a start or stop fails, you see one message here and nothing is retried.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Text(obs.status)
                .font(.caption.bold())
                .foregroundStyle(obs.isConnected ? Color.green : Color.secondary)
                .accessibilityLabel(AccessibilityLabels.obsStatus(enabled: enabled, status: obs.status, error: obs.lastError))
            if enabled, let e = obs.lastError {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { if enabled { OBSIntegration.shared.startIfEnabled() } }
        .onChange(of: enabled) { _, _ in OBSIntegration.shared.settingsChanged() }
        .onChange(of: host) { _, _ in OBSIntegration.shared.settingsChanged() }
        .onChange(of: port) { _, _ in OBSIntegration.shared.settingsChanged() }
        .onChange(of: password) { _, _ in OBSIntegration.shared.settingsChanged() }
    }

    private func scenePicker(_ title: String, selection: Binding<String>, role: String) -> some View {
        let names = obs.scenes.contains(selection.wrappedValue) || selection.wrappedValue.isEmpty
            ? obs.scenes : [selection.wrappedValue] + obs.scenes
        return Picker(title, selection: selection) {
            Text("Leave unchanged").tag("")
            ForEach(names, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!switchScenes || !enabled)
        .accessibilityLabel(AccessibilityLabels.obsScene(role: role, scene: selection.wrappedValue))
    }

    private func runTest() {
        testing = true; testResult = nil
        let (h, p, pw) = (host.trimmingCharacters(in: .whitespaces).isEmpty ? OBSPrefs.defaultHost : host, port, password)
        Task {
            let r = await OBSIntegration.testConnection(host: h, port: p, password: pw)
            switch r {
            case .success(let v): testResult = "Connected to OBS \(v.obsVersion)"
            case .failure(let e): testResult = e.localizedDescription
            }
            testing = false
        }
    }
}
#endif
