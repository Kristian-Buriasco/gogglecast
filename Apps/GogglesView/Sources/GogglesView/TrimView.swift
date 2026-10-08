import AVKit
import SwiftUI

enum TrimMath {
    /// Clamps to [0, duration] and keeps at least `minLength` between handles.
    /// `movedStart` says which handle the user dragged, so the other one yields.
    static func clamp(start: Double, end: Double, duration: Double, minLength: Double = 0.5, movedStart: Bool) -> (start: Double, end: Double) {
        let dur = max(duration, 0), minL = min(minLength, dur)
        var s = min(max(start, 0), dur), e = min(max(end, 0), dur)
        if e - s < minL {
            if movedStart { s = max(0, e - minL); e = max(e, s + minL) } else { e = min(dur, s + minL); s = min(s, e - minL) }
        }
        return (max(s, 0), min(e, dur))
    }
}

@MainActor
final class TrimModel: ObservableObject {
    let clip: Clip
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var progress: Float = 0
    @Published var exporting = false
    @Published var error: String?
    private var session: AVAssetExportSession?

    init(clip: Clip) {
        self.clip = clip
        player = AVPlayer(url: clip.url)
        Task {
            let d = (try? await player.currentItem?.asset.load(.duration))?.seconds ?? clip.duration ?? 0
            duration = d.isFinite ? d : 0
            end = duration
        }
    }

    func setStart(_ v: Double) { (start, end) = TrimMath.clamp(start: v, end: end, duration: duration, movedStart: true); seek(start) }
    func setEnd(_ v: Double) { (start, end) = TrimMath.clamp(start: start, end: v, duration: duration, movedStart: false); seek(end) }
    func seek(_ t: Double) { player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }

    /// Passthrough: no re-encode, so cut points snap to the nearest preceding keyframe.
    func export(done: @escaping (URL) -> Void) {
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: clip.url), presetName: AVAssetExportPresetPassthrough) else {
            error = "Export not available for this file"; return
        }
        let out = ClipLibrary.trimOutputURL(for: clip.url)
        s.outputURL = out
        s.outputFileType = clip.url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        s.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        session = s; exporting = true; error = nil; progress = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.progress = self?.session?.progress ?? 0 }
        }
        s.exportAsynchronously { [weak self] in
            Task { @MainActor in
                timer.invalidate()
                guard let self else { return }
                self.exporting = false
                if s.status == .completed {
                    ClipMetadataStore.carryOver(from: self.clip.url, to: out)
                    ClipLibrary.writeMarkers(ClipLibrary.trimmedMarkers(self.clip.markers, start: self.start, end: self.end), for: out)
                    done(out)
                } else { self.error = s.error?.localizedDescription ?? "Export failed" }
            }
        }
    }

    func cancel() { session?.cancelExport(); player.pause() }
}

struct TrimView: View {
    @StateObject private var model: TrimModel
    let onClose: () -> Void

    init(clip: Clip, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TrimModel(clip: clip))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trim \(model.clip.name)").font(.headline).lineLimit(1)
            VideoPlayer(player: model.player).frame(minHeight: 260)
            if model.duration > 0 {
                HandleRow(label: "Start", value: model.start, range: 0...model.duration, markers: model.clip.markers,
                          set: model.setStart)
                HandleRow(label: "End", value: model.end, range: 0...model.duration, markers: model.clip.markers,
                          set: model.setEnd)
                Text("Length \(ClipLibrary.formatDuration(model.end - model.start)) · passthrough, cuts snap to keyframes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                if model.exporting { ProgressView(value: model.progress).frame(width: 160) }
                Spacer()
                Button("Cancel") { model.cancel(); onClose() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    model.export { url in
                        NSWorkspace.shared.activateFileViewerSelecting([url]); onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.exporting || model.duration == 0)
            }
        }
        .padding(16)
        .frame(width: 640)
    }
}

private struct HandleRow: View {
    let label: String, value: Double, range: ClosedRange<Double>, markers: [ClipMarker], set: (Double) -> Void

    var body: some View {
        HStack {
            Text(label).frame(width: 40, alignment: .leading)
            VStack(spacing: 0) {
                Slider(value: Binding(get: { value }, set: set), in: range)
                    .accessibilityLabel("\(label) time")
                    .accessibilityValue("\(Int(value.rounded())) seconds")
                if !markers.isEmpty {
                    GeometryReader { g in
                        ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                            Rectangle().fill(m.isAuto ? Color.cyan : Color.orange).frame(width: 2, height: 8)
                                .accessibilityElement()
                                .accessibilityLabel(m.isAuto ? "Automatic marker \(m.label)" : "Marker \(m.label)")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Moves the \(label.lowercased()) handle to this marker")
                                .accessibilityAction { set(m.t) }
                                .position(x: 8 + (g.size.width - 16) * CGFloat(m.t / max(range.upperBound, 0.001)), y: 4)
                                .onTapGesture { set(m.t) }
                                .help(m.isAuto ? "\(m.label) (automatic)" : m.label)
                        }
                    }.frame(height: 10)
                }
            }
            Text(ClipLibrary.formatDuration(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
