import Foundation

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// task-gui-v2 point 5 (approved scope, exact content):
//   - Launch at login toggle, wired to the real SMAppService flow
//     (`SettingsViewModel`/`HelperRegistration`).
//   - Helper status display + "Re-register" recovery button.
//   - Reconnect button (calls the same `GogglesConnectionCoordinator
//     .reconnect()` the menu bar's "Reconnect" item already calls).
// A genuine standalone SwiftUI view/window (see `SettingsWindowController`
// for how it's opened), not a sheet on the main video window -- the footer's
// "Settings" button (`GogglesConnectionView.swift`) opens it.
// ─────────────────────────────────────────────────────────────────────────

struct SettingsView: View {
    /// Taller window for `--settings-shot`, so a whole tab fits in one picture. Nil in normal use.
    static var heightOverride: CGFloat?

    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var profileContext = ProfileContext.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", display = "Display", picture = "Picture", recording = "Recording", streaming = "Streaming"
        case outputs = "Outputs", integrations = "Integrations", advanced = "Advanced"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("General")
            case .display: return L("Display")
            case .picture: return L("Picture")
            case .outputs: return L("Outputs")
            case .integrations: return L("Integrations")
            case .recording: return L("Recording")
            case .streaming: return L("Streaming")
            case .advanced: return L("Advanced")
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .display: return "display"
            case .picture: return "wand.and.stars"
            case .outputs: return "tv.and.mediabox"
            case .integrations: return "puzzlepiece.extension"
            case .recording: return "record.circle"
            case .streaming: return "antenna.radiowaves.left.and.right"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @AppStorage("settingsTab") private var tabRaw = Tab.general.rawValue
    private var tab: Binding<Tab> {
        Binding(get: { Tab(rawValue: tabRaw) ?? .general }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tab.wrappedValue.title)
                        .font(.title2.bold())
                        .padding(.bottom, 2)
                    switch tab.wrappedValue {
                    case .general:
                        startupSection
                        UpdateSettingsSection()
                        PresetsSettingsSection()
                        ProfileSettingsSection(deviceSerial: profileContext.serial)
                        SettingsBackupSection()
                    case .display:
                        appearanceSection
                        RaceModeSettingsSection()
                        osdSection
                        OrientationSettingsSection()
                        ExposureSettingsSection()
                        windowsSection
                    case .picture:
                        StabilizerSettingsSection()
                        EnhanceSettingsSection()
                        FramingSettingsSection()
                        LookSettingsSection()
                    case .recording:
                        recordingSection
                        RecordingExtrasSettingsSection()
                        AutoMarkerSettingsSection()
                        ReplaySettingsSection()
                        BurnInSettingsSection()
                        OutputFramingSettingsSection()
                        GallerySettingsRow()
                    case .streaming:
                        ReencodeSettingsSection()
                        NetworkStreamSettingsSection()
                    case .outputs:
                        RTMPSettingsSection()
                        SRTSettingsSection()
                        NDISettingsSection()
                        WebViewerSettingsSection()
                        ProgramOutputSettingsSection()
                    case .integrations:
                        OBSSettingsSection()
                        EventHooksSettingsSection()
                        AutomationSettingsSection()
                        AutoOpenSettingsSection()
                    case .advanced:
                        TroubleshootingSection(viewModel: viewModel)
                        GlobalHotkeysSettingsSection()
                        SignalAlertSettingsSection()
                        developerToolsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 780, height: Self.heightOverride ?? 680, alignment: .topLeading)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.primary)
        .onAppear { viewModel.refresh() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab.wrappedValue = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).frame(width: 20).accessibilityHidden(true)
                        Text(t.title)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(tab.wrappedValue == t ? AppChrome.selectedFill : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab.wrappedValue == t ? .isSelected : [])
            }
            Spacer()
            Text(verbatim: "GogglesView \(UpdateChecker.currentVersion)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(.top, 40).padding(.horizontal, 12).padding(.bottom, 16)
        .frame(width: 180)
        .background(AppChrome.sidebarFill)
    }

    /// One settings group: a rounded card with generous padding.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppChrome.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppChrome.cardStroke))
    }

    private var startupSection: some View {
        SettingsGroup("Startup") {
            SettingsToggleRow("Launch GogglesView at login", isOn: Binding(
                get: { viewModel.isLaunchAtLoginEnabled },
                set: { viewModel.setLaunchAtLogin($0) }
            ), help: viewModel.actionMessage.map { LocalizedStringKey($0) })
            .accessibilityIdentifier("launchAtLoginToggle")
            MenuBarItemSettingsToggle()
            SettingsRow("Background service") {
                Circle().fill(viewModel.statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(viewModel.statusDescription)
                    .accessibilityIdentifier("helperStatusText")
                if viewModel.showsReRegisterButton {
                    Button("Re-register") { viewModel.reRegister() }
                        .accessibilityIdentifier("reRegisterButton")
                }
            }
        }
    }

    @AppStorage(RecordingPrefs.folderKey) private var recordingFolder = ""
    @AppStorage(RecordingPrefs.containerKey) private var recordingContainer = RecordingPrefs.Container.mov.rawValue
    @AppStorage(RecordingPrefs.prefixKey) private var recordingPrefix = ""
    @AppStorage(RecordingPrefs.autoStartKey) private var recordingAutoStart = false

    @AppStorage(OSDPrefs.enabledKey) private var osdEnabled = false
    @AppStorage(OSDPrefs.showFpsKey) private var osdFps = true
    @AppStorage(OSDPrefs.showBitrateKey) private var osdBitrate = true
    @AppStorage(OSDPrefs.showResolutionKey) private var osdResolution = true
    @AppStorage(OSDPrefs.showDropsKey) private var osdDrops = false
    @AppStorage(OSDPrefs.showLatencyKey) private var osdLatency = true
    @AppStorage(OSDPrefs.showBatteryKey) private var osdBattery = true

    @AppStorage(AppearancePreference.key) private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearanceSection: some View {
        SettingsGroup("Appearance") {
            SettingsRow("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden().frame(width: 260)
                .onChange(of: appearanceRaw) { _, _ in AppearancePreference.applyStored() }
            }
        }
    }

    private var osdSection: some View {
        SettingsGroup("On-screen display") {
            SettingsToggleRow("Show stats over the video", isOn: $osdEnabled)
            SettingsToggleRow("Resolution", isOn: $osdResolution, indented: true).disabled(!osdEnabled)
            SettingsToggleRow("Framerate", isOn: $osdFps, indented: true).disabled(!osdEnabled)
            SettingsToggleRow("Bitrate", isOn: $osdBitrate, indented: true).disabled(!osdEnabled)
            SettingsToggleRow("Latency (stream in to decoded picture)", isOn: $osdLatency, indented: true).disabled(!osdEnabled)
            SettingsToggleRow("Dropped frames", isOn: $osdDrops, indented: true).disabled(!osdEnabled)
            SettingsToggleRow("Goggles battery", isOn: $osdBattery, indented: true).disabled(!osdEnabled)
        }
    }

    private var recordingSection: some View {
        SettingsGroup("Recording") {
            SettingsRow("Folder", help: "Records the goggles' stream as-is (no re-encoding), so quality is whatever the goggles send.") {
                Text(recordingFolder.isEmpty ? Recorder.defaultDirectory.path : recordingFolder)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 100, alignment: .leading)
                Button("Open") { RecordingPrefs.openFolder() }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { recordingFolder = url.path }
                }
            }
            SettingsRow("Format") {
                Picker("Format", selection: $recordingContainer) {
                    ForEach(RecordingPrefs.Container.allCases) { Text(verbatim: ".\($0.ext)").tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            SettingsRow("File name prefix") {
                TextField("File name prefix", text: $recordingPrefix, prompt: Text("GogglesView"))
                    .labelsHidden().settingsField(width: 240, mono: false)
            }
            SettingsToggleRow("Start recording automatically when live", isOn: $recordingAutoStart)
        }
    }

    private var windowsSection: some View {
        SettingsGroup("Windows") {
            SettingsToggleRow("Show capture window (for OBS Window Capture)", isOn: $viewModel.captureWindowEnabled)
                .disabled(viewModel.captureWindowHandler == nil)
                .accessibilityIdentifier("captureWindowToggle")
            SettingsToggleRow("Keep on top", isOn: $viewModel.captureWindowOnTop, indented: true)
                .accessibilityIdentifier("captureWindowOnTopToggle")
            MiniWindowSettingsSection()
        }
    }

    private var developerToolsSection: some View {
        SettingsGroup("Developer tools") {
            BenchmarkSettingsSection()
            SelfTestSettingsSection()
            SessionLogSettingsSection()
        }
        .accessibilityIdentifier("developerToolsGroup")
    }
}

/// One-line health state plus the recovery actions, reusing what the setup assistant computes.
struct TroubleshootingSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var model = SetupAssistantModel(env: OnboardingWindow.environment)
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsGroup("Troubleshooting") {
            SettingsRow("Health") {
                Circle()
                    .fill(model.isComplete ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(SetupDiagnosis.healthLine(model.steps))
                    .accessibilityIdentifier("healthLineText")
            }
            SettingsRow("Setup") {
                Button("Open setup assistant") { OnboardingWindow.show() }
                    .accessibilityHint("Opens a guided checklist for the background service, USB connection and video")
                    .accessibilityIdentifier("openSetupAssistantButton")
            }
            SettingsRow("Connection", help: viewModel.reconnectHandler == nil ? LocalizedStringKey(L("No device selected yet.")) : nil) {
                Button("Reconnect") { viewModel.reconnectHandler?() }
                    .disabled(viewModel.reconnectHandler == nil)
                    .accessibilityIdentifier("settingsReconnectButton")
                Button("Connection health") { HealthWindow.show() }
            }
            DiagnosticsSettingsSection()
        }
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in model.refresh() }
    }
}
#endif
