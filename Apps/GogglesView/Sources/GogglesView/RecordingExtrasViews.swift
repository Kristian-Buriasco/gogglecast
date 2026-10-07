import SwiftUI

/// Marker menu shown next to the record button; enabled only while recording.
struct MarkerControl: View {
    @ObservedObject var recorder: Recorder
    @State private var custom = ""
    @State private var showCustom = false

    init(recorder: Recorder) { self.recorder = recorder }

    var body: some View {
        Menu {
            ForEach(RecordingMarkers.defaultLabels, id: \.self) { label in
                Button(label) { recorder.addMarker(label: label) }
            }
            Divider()
            Button("Marker…") { custom = ""; showCustom = true }
        } label: {
            Image(systemName: recorder.markers.isEmpty ? "mappin" : "mappin.circle.fill")
                .foregroundStyle(recorder.isRecording ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!recorder.isRecording)
        .help("Add a marker to the recording (saved to a .markers.json sidecar)")
        .accessibilityLabel("Add recording marker")
        .accessibilityIdentifier("markerButton")
        .alert("Add marker", isPresented: $showCustom) {
            TextField("Label", text: $custom)
            Button("Add") { recorder.addMarker(label: custom.isEmpty ? "Marker" : custom) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct RecordingExtrasSettingsSection: View {
    @AppStorage(RecordingExtras.splitMinutesKey) private var splitMinutes = 0
    @AppStorage(RecordingExtras.splitMegabytesKey) private var splitMegabytes = 0
    @AppStorage(RecordingExtras.loopKeepMinutesKey) private var loopKeep = 0
    @AppStorage(RecordingExtras.autoDeleteDaysKey) private var autoDeleteDays = 0

    var body: some View {
        Section("Recording extras") {
            field("Split every", $splitMinutes, range: 0...120, step: 5, unit: "min",
                  caption: "Starts a new -partN file at the next clean cut point; recording continues. Ignored in loop mode.")
            field("Split at size", $splitMegabytes, range: 0...100_000, step: 500, unit: "MB",
                  caption: "Also splits when a file reaches this size.")
            field("Loop recording: keep only the last", $loopKeep, range: 0...100_000, step: 5, unit: "min",
                  caption: "Older parts are permanently deleted (not moved to the Trash). Recording is split into parts of one sixth of this length, and only parts from the current recording are deleted.")
            field("Auto-delete after", $autoDeleteDays, range: 0...3650, step: 1, unit: "days",
                  caption: "At launch, moves recordings (.mov, .mp4 and .json files starting with your prefix) older than this to the Trash. Files from the last 24 hours and instant replay clips are never touched.")
        }
        .onChange(of: autoDeleteDays) { old, new in
            guard old == 0, new > 0 else { return }
            if !Self.confirmAutoDelete(days: new) { autoDeleteDays = 0 }
        }
    }

    /// Asks before auto-delete is switched on, because it removes files without a prompt later.
    static func confirmAutoDelete(days: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move old recordings to the Trash?"
        alert.informativeText = RecordingExtras.autoDeleteConfirmation(days: days, folder: RecordingPrefs.directory)
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func field(_ title: String, _ value: Binding<Int>, range: ClosedRange<Int>, step: Int,
                       unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: value, in: range, step: step) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(RecordingExtras.valueLabel(value.wrappedValue, unit: unit))
                        .monospacedDigit()
                        .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
