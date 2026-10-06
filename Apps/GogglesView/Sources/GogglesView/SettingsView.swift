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
        case general = "General", display = "Display", recording = "Recording", streaming = "Streaming", advanced = "Advanced"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .display: return "display"
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
                    Text(tab.wrappedValue.rawValue)
                        .font(.title2.bold())
                        .padding(.bottom, 2)
                    switch tab.wrappedValue {
                    case .general:
                        card { launchAtLoginSection }
                        card { AutoOpenSettingsSection() }
                        card { PresetsSettingsSection() }
                        card { ProfileSettingsSection(deviceSerial: profileContext.serial) }
                        card { UpdateSettingsSection() }
                        card { MenuBarItemSettingsToggle() }
                    case .display:
                        card { osdSection }
                        card { StabilizerSettingsSection() }
                        card { FramingSettingsSection() }
                        card { OutputFramingSettingsSection() }
                        card { LookSettingsSection() }
                        card { OrientationSettingsSection() }
                        card { captureWindowSection }
                        card { MiniWindowSettingsSection() }
                    case .recording:
                        card { recordingSection }
                        card { RecordingExtrasSettingsSection() }
                        card { ReplaySettingsSection() }
                        card { BurnInSettingsSection() }
                        card { GallerySettingsRow() }
                    case .streaming:
                        card { ReencodeSettingsSection() }
                        card { NetworkStreamSettingsSection() }
                        card { RTMPSettingsSection() }
                        card { WebViewerSettingsSection() }
                        card { SRTSettingsSection() }
                        card { NDISettingsSection() }
                    case .advanced:
                        card { GlobalHotkeysSettingsSection() }
                        card { EventHooksSettingsSection() }
                        card { AutomationSettingsSection() }
                        card { SessionLogSettingsSection() }
                        card { helperStatusSection }
                        card { connectionSection }
                        card { DiagnosticsSettingsSection() }
                        card { OnboardingSettingsSection() }
                        card { SelfTestSettingsSection() }
                        card { BenchmarkSettingsSection() }
                        card { ConnectionHealthSettingsSection() }

                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 780, height: Self.heightOverride ?? 580, alignment: .topLeading)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onAppear { viewModel.refresh() }
        .onDisappear { viewModel.stopPolling() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button { tab.wrappedValue = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).frame(width: 20).accessibilityHidden(true)
                        Text(t.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(tab.wrappedValue == t ? Color.white.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab.wrappedValue == t ? .isSelected : [])
            }
            Spacer()
            Text("GogglesView \(UpdateChecker.currentVersion)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(.top, 40).padding(.horizontal, 12).padding(.bottom, 16)
        .frame(width: 180)
        .background(Color.white.opacity(0.03))
    }

    /// One settings group: a rounded card with generous padding.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Startup").font(.headline)
            Toggle(isOn: Binding(
                get: { viewModel.isLaunchAtLoginEnabled },
                set: { viewModel.setLaunchAtLogin($0) }
            )) {
                Text("Launch GogglesView at login")
            }
            .accessibilityIdentifier("launchAtLoginToggle")

            if let message = viewModel.actionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settingsActionMessage")
            }
        }
    }

    private var helperStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Helper daemon").font(.headline)
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(viewModel.statusDescription)
                    .font(.caption)
                    .accessibilityIdentifier("helperStatusText")
            }
            if viewModel.showsReRegisterButton {
                Button("Re-register") {
                    viewModel.reRegister()
                }
                .accessibilityIdentifier("reRegisterButton")
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

    private var osdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-screen display").font(.headline)
            Toggle("Show stats over the video", isOn: $osdEnabled)
            Group {
                Toggle("Resolution", isOn: $osdResolution)
                Toggle("Framerate", isOn: $osdFps)
                Toggle("Bitrate", isOn: $osdBitrate)
                Toggle("Latency (stream in to decoded picture)", isOn: $osdLatency)
                Toggle("Dropped frames", isOn: $osdDrops)
                Toggle("Goggles battery", isOn: $osdBattery)
            }
            .padding(.leading, 16)
            .disabled(!osdEnabled)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording").font(.headline)
            HStack {
                Text(recordingFolder.isEmpty ? Recorder.defaultDirectory.path : recordingFolder)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open") { RecordingPrefs.openFolder() }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { recordingFolder = url.path }
                }
            }
            Picker("Format", selection: $recordingContainer) {
                ForEach(RecordingPrefs.Container.allCases) { Text(".\($0.ext)").tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            TextField("File name prefix", text: $recordingPrefix, prompt: Text("GogglesView"))
            Toggle("Start recording automatically when live", isOn: $recordingAutoStart)
            Text("Records the goggles' stream as-is (no re-encoding), so quality is whatever the goggles send.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var captureWindowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capture window").font(.headline)
            Toggle("Show capture window (for OBS Window Capture)", isOn: $viewModel.captureWindowEnabled)
                .disabled(viewModel.captureWindowHandler == nil)
                .accessibilityIdentifier("captureWindowToggle")
            Toggle("Keep on top", isOn: $viewModel.captureWindowOnTop)
                .accessibilityIdentifier("captureWindowOnTopToggle")
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            Button("Reconnect") {
                viewModel.reconnectHandler?()
            }
            .disabled(viewModel.reconnectHandler == nil)
            .accessibilityIdentifier("settingsReconnectButton")
            if viewModel.reconnectHandler == nil {
                Text("No device selected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
