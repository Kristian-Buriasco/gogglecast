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
            field("Split every (minutes)", $splitMinutes, range: 0...120,
                  caption: "0 = off. Starts a new -partN file at the next keyframe; recording continues. Ignored in loop mode.")
            field("Split at size (MB)", $splitMegabytes, range: 0...100_000,
                  caption: "0 = off. Also splits when a file reaches this size.")
            field("Loop: keep last (minutes)", $loopKeep, range: 0...100_000,
                  caption: "0 = off. Splits into segments of N/6 minutes and deletes this session's oldest segments beyond N minutes. Other files are never touched.")
            field("Auto-delete after (days)", $autoDeleteDays, range: 0...3650,
                  caption: "0 = off. At launch, moves recordings (.mov/.mp4/.json starting with your prefix) older than this to the Trash.")
        }
    }

    private func field(_ title: String, _ value: Binding<Int>, range: ClosedRange<Int>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onChange(of: value.wrappedValue) { v in
                        let c = min(max(v, range.lowerBound), range.upperBound)
                        if c != v { value.wrappedValue = c }
                    }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
