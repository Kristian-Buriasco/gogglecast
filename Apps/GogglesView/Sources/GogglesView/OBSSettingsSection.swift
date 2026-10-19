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
    @State private var feedScene = ""
    @State private var feedProto = OBSFeedProtocol.srt
    @State private var feedResult: String?
    @AppStorage(FeedPortPrefs.perFeedKey) private var perFeed = true
    @ObservedObject private var program = ProgramOutputController.shared
    @State private var testing = false

    private func addFeeds() {
        let scene = feedScene.isEmpty ? (obs.scenes.first ?? "") : feedScene
        let feeds = program.available.map { (name: $0.name, slot: FeedSlots.shared.slot(deviceId: $0.id)) }
        let proto = feedProto
        feedResult = nil
        Task { feedResult = await OBSIntegration.shared.addFeedSources(scene: scene, proto: proto, feeds: feeds) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("OBS Studio",
                          info: "Connect to OBS over its WebSocket server to start recording and switch scenes when your goggles go live. Off by default. GogglesView only talks to the host you enter here.") {
                SettingsToggleRow("Connect to OBS", isOn: $enabled, accessibilityName: "Connect to OBS Studio")
                Group {
                    SettingsRow("Host", indented: true) {
                        TextField("Host", text: $host, prompt: Text(OBSPrefs.defaultHost)).labelsHidden()
                            .settingsField(width: 220)
                            .accessibilityLabel("OBS host")
                    }
                    SettingsRow("Port", indented: true) {
                        TextField("Port", value: $port, format: .number.grouping(.never)).labelsHidden()
                            .settingsField(width: 90)
                            .accessibilityLabel("OBS WebSocket port")
                    }
                    SettingsRow("Password", help: "Stored in the macOS Keychain.", indented: true) {
                        SettingsSecretField(title: "Password",
                                            text: Binding(get: { password }, set: { password = $0; OBSIntegration.shared.settingsChanged() }),
                                            prompt: "Leave empty if OBS has none", width: 220,
                                            onReveal: { _password.load() })
                            .accessibilityLabel("OBS WebSocket password")
                    }
                    SettingsRow("Connection", help: testResult.map { LocalizedStringKey($0) }, indented: true) {
                        Button(testing ? L("Testing...") : L("Test connection")) { runTest() }
                            .disabled(testing)
                            .accessibilityLabel("Test OBS connection")
                    }
                }
                .disabled(!enabled)
                SettingsRow("Status", help: (enabled ? obs.lastError : nil).map { LocalizedStringKey($0) }) {
                    Text(obs.status)
                        .font(.caption.bold())
                        .foregroundStyle(obs.isConnected ? Color.green : Color.secondary)
                        .accessibilityLabel(AccessibilityLabels.obsStatus(enabled: enabled, status: obs.status, error: obs.lastError))
                }
            }
            SettingsGroup("Rules while connected",
                          info: "Only affects a recording GogglesView started in OBS. If a start or stop fails, you see one message here and nothing is retried.") {
                Group {
                    SettingsToggleRow("Record in OBS while I'm live", isOn: $recordWithStream)
                    SettingsRow("Stop after signal loss", indented: true) {
                        Stepper(value: $grace, in: OBSPrefs.graceRange, step: 5) {
                            Text(verbatim: "\(grace) s").monospacedDigit()
                        }
                        .fixedSize()
                        .accessibilityLabel("Stop OBS recording after signal loss")
                        .accessibilityValue(AccessibilityLabels.quantity(grace, unit: L("seconds")))
                    }
                    .disabled(!recordWithStream)
                    SettingsToggleRow("Switch OBS scenes", isOn: $switchScenes)
                    scenePicker(L("Scene when live"), selection: $liveScene, role: "live")
                    scenePicker(L("Scene when lost"), selection: $lostScene, role: "lost")
                    SettingsToggleRow("Stop the OBS recording when I stop mine", isOn: $stopWithMine)
                }
                .disabled(!enabled)
            }
            SettingsGroup("Several goggles",
                          info: "Creates one Media Source per open goggles, named after the feed (rename feeds under Program output). Press the SRT or UDP button in each window to start sending. Existing sources are updated, never deleted.") {
                SettingsToggleRow("Separate port for each goggles window", isOn: $perFeed,
                                  help: "Window 1 uses the port in Settings, window 2 the next one, and so on.",
                                  info: "Window 1 uses the port in Settings, window 2 the next one, and so on (NDI adds a number to the name). Needed to send several goggles at once.")
                Group {
                    SettingsRow("Scene") {
                        Picker("Scene", selection: $feedScene) {
                            ForEach(obs.scenes, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                    SettingsRow("Using") {
                        Picker("Using", selection: $feedProto) {
                            Text(verbatim: "SRT").tag(OBSFeedProtocol.srt)
                            Text(verbatim: "UDP").tag(OBSFeedProtocol.udp)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    }
                    SettingsRow("Feeds", help: feedResult.map { LocalizedStringKey($0) }) {
                        Button("Add all feeds to OBS") { addFeeds() }
                            .disabled(!obs.isConnected || program.available.isEmpty || (feedScene.isEmpty && obs.scenes.isEmpty))
                    }
                }
                .disabled(!enabled)
            }
        }
        .onAppear { if enabled { _password.load(); OBSIntegration.shared.startIfEnabled() } }
        .onChange(of: enabled) { _, on in if on { _password.load() }; OBSIntegration.shared.settingsChanged() }
        .onChange(of: host) { _, _ in OBSIntegration.shared.settingsChanged() }
        .onChange(of: port) { _, _ in OBSIntegration.shared.settingsChanged() }
    }

    private func scenePicker(_ title: String, selection: Binding<String>, role: String) -> some View {
        let names = obs.scenes.contains(selection.wrappedValue) || selection.wrappedValue.isEmpty
            ? obs.scenes : [selection.wrappedValue] + obs.scenes
        return SettingsRow(LocalizedStringKey(title), indented: true) {
            Picker(title, selection: selection) {
                Text("Leave unchanged").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 200)
            .accessibilityLabel(AccessibilityLabels.obsScene(role: role, scene: selection.wrappedValue))
        }
        .disabled(!switchScenes || !enabled)
    }

    private func runTest() {
        testing = true; testResult = nil
        let (h, p, pw) = (host.trimmingCharacters(in: .whitespaces).isEmpty ? OBSPrefs.defaultHost : host, port, password)
        Task {
            let r = await OBSIntegration.testConnection(host: h, port: p, password: pw)
            switch r {
            case .success(let v): testResult = L("Connected to OBS %@", v.obsVersion)
            case .failure(let e): testResult = e.localizedDescription
            }
            testing = false
        }
    }
}
#endif
