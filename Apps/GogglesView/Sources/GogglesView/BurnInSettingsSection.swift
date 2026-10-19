import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Capture-tab settings for the re-encoded burn-in recording.
struct BurnInSettingsSection: View {
    @AppStorage(BurnInPrefs.logoFileKey) private var logoFile = ""
    @AppStorage(BurnInPrefs.cornerKey) private var corner = BurnInCorner.topRight.rawValue
    @AppStorage(BurnInPrefs.scaleKey) private var scale = BurnInPrefs.defaultScale
    @AppStorage(BurnInPrefs.opacityKey) private var opacity = BurnInPrefs.defaultOpacity
    @AppStorage(BurnInPrefs.showTimeKey) private var showTime = false
    @AppStorage(BurnInPrefs.showStatsKey) private var showStats = false
    @AppStorage(BurnInPrefs.codecKey) private var codec = BurnInCodec.h264.rawValue
    @AppStorage(BurnInPrefs.bitrateKey) private var bitrate = BurnInPrefs.defaultBitrate
    @AppStorage(BurnInPrefs.containerKey) private var container = RecordingPrefs.Container.mov.rawValue
    @State private var importError: String?

    var body: some View {
        SettingsGroup("Burn-in recording") {
            SettingsRow("Logo", info: "Decodes and re-encodes the stream (⇧⌘B) to a separate “-burned” file in the recordings folder. Uses noticeably more CPU/GPU than normal recording; both can run at once.") {
                preview
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Choose logo…") { chooseLogo() }
                        Button("Remove") { BurnInPrefs.clearLogo(); logoFile = "" }
                            .disabled(logoFile.isEmpty)
                    }
                    if let importError {
                        Text(importError).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            SettingsRow("Corner", indented: true) {
                Picker("Corner", selection: $corner) {
                    ForEach(BurnInCorner.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 140)
            }
            slider(L("Logo size"), value: $scale, range: BurnInPrefs.scaleRange, suffix: L("% of width"))
            slider(L("Opacity"), value: $opacity, range: BurnInPrefs.opacityRange, suffix: "%")
            SettingsToggleRow("Burn in current time", isOn: $showTime)
            SettingsToggleRow("Burn in stream stats (resolution, fps, bitrate)", isOn: $showStats)
            SettingsRow("Codec") {
                Picker("Codec", selection: $codec) {
                    ForEach(BurnInCodec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            SettingsRow("Format") {
                Picker("Format", selection: $container) {
                    ForEach(RecordingPrefs.Container.allCases) { Text(verbatim: ".\($0.ext)").tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            SettingsRow("Bitrate") {
                TextField("Bitrate", value: Binding(
                    get: { bitrate },
                    set: { bitrate = BurnInPrefs.clamp($0, to: BurnInPrefs.bitrateRange) }),
                    format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .settingsField(width: 100, unit: "Mbps")
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let image = logoFile.isEmpty ? nil : BurnInPrefs.logoURL.flatMap { NSImage(contentsOf: $0) }
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
                    .opacity(Double(opacity) / 100)
            } else {
                Text("No logo").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? L("Logo preview, no logo selected") : L("Logo preview"))
        .id(logoFile)
    }

    private func slider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        SettingsSliderRow(LocalizedStringKey(title), value: Binding(get: { Double(value.wrappedValue) },
                                                set: { value.wrappedValue = BurnInPrefs.clamp(Int($0.rounded()), to: range) }),
                          range: Double(range.lowerBound)...Double(range.upperBound), unit: suffix)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let dest = try BurnInPrefs.importLogo(from: url)
            logoFile = dest.lastPathComponent
            importError = nil
        } catch {
            importError = L("Couldn't import: %@", error.localizedDescription)
        }
    }
}
