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
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.bold())
                .padding(.top, 6)

            launchAtLoginSection
            Divider()
            helperStatusSection
            Divider()
            connectionSection
            Divider()
            recordingSection

            captureWindowSection

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 380, height: 600, alignment: .top)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onAppear { viewModel.refresh() }
        .onDisappear { viewModel.stopPolling() }
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

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording").font(.headline)
            HStack {
                Text(recordingFolder.isEmpty ? Recorder.defaultDirectory.path : recordingFolder)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
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
