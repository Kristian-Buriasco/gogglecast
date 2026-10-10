import Foundation

// Operator overview: one window with a row per open goggles (name, state, fps, battery, recording)
// and Record all / Stop all, plus how much disk is left for the recordings. For events with several
// goggles, where walking through every window to see who is live is too slow. Recording controls
// only appear while something records.

struct OverviewRow: Equatable, Identifiable {
    enum Health: Equatable { case good, warning, bad }

    let id: String          // deviceId
    var name: String
    var status: String
    var health: Health
    var isLive: Bool
    var fps: Int?
    var battery: Int?
    var isRecording: Bool
    var elapsed: TimeInterval
}

enum OverviewLogic {
    static func health(for kind: GogglesUIStateKind) -> OverviewRow.Health {
        switch kind {
        case .live: return .good
        case .claiming, .resolving, .handshaking, .waitingForKeyframe, .stalled: return .warning
        case .noHelper, .noDevice, .claimFailed: return .bad
        }
    }

    /// Windows to toggle for "Stop all": everything that is recording.
    static func toStopRecording(_ rows: [OverviewRow]) -> [String] { rows.filter(\.isRecording).map(\.id) }

    /// A recording of 1080p60 re-encoded at the default bitrate is about 9 GB an hour. A conservative
    /// figure on purpose: a warning that comes too early costs nothing, one that comes too late does.
    static let bytesPerRecordingHour: Double = 9_000_000_000

    enum DiskLevel: Equatable { case ok, low, critical, unknown }

    /// Hours of recording left on the disk, for `recordings` simultaneous recordings (at least one).
    static func hoursLeft(freeBytes: Int64, recordings: Int) -> Double {
        Double(max(freeBytes, 0)) / (bytesPerRecordingHour * Double(max(recordings, 1)))
    }

    static func diskLevel(freeBytes: Int64?, recordings: Int) -> DiskLevel {
        guard let freeBytes else { return .unknown }
        let h = hoursLeft(freeBytes: freeBytes, recordings: recordings)
        return h < 1 ? .critical : (h < 3 ? .low : .ok)
    }

    static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

final class OperatorOverviewModel: ObservableObject {
    @Published private(set) var rows: [OverviewRow] = []
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var folderName = ""

    private var sessions: () -> [GogglesSession] = { [] }
    private var timer: Timer?

    func start(sessions: @escaping () -> [GogglesSession]) {
        self.sessions = sessions
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    var recordingCount: Int { rows.filter(\.isRecording).count }
    var diskLevel: OverviewLogic.DiskLevel { OverviewLogic.diskLevel(freeBytes: freeBytes, recordings: recordingCount) }

    func refresh() {
        let all = sessions()
        let names = Dictionary(uniqueKeysWithValues: ProgramOutputController.shared.available.map { ($0.id, $0.name) })
        let next: [OverviewRow] = all.map { s in
            let c = s.coordinator
            let rec = SessionControlBoard.shared.recorder(for: s.decodeSession)
            let kind = c.uiState.kind
            return OverviewRow(
                id: s.deviceId, name: names[s.deviceId] ?? s.label,
                status: MenuBarController.displayText(for: c.uiState, stats: c.stats),
                health: OverviewLogic.health(for: kind), isLive: kind == .live,
                fps: c.stats?.fps, battery: c.batteryPercent,
                isRecording: rec?.isRecording ?? false, elapsed: rec?.elapsed ?? 0)
        }
        if next != rows { rows = next }
        let folder = RecordingPrefs.directory
        freeBytes = Recorder.volumeCapacity(at: folder)
        folderName = folder.lastPathComponent
    }

    private func toggleRecording(_ ids: [String]) {
        for s in sessions() where ids.contains(s.deviceId) {
            NotificationCenter.default.post(name: .gogglesToggleRecording, object: s.decodeSession)
        }
    }

    func stopAll() { toggleRecording(OverviewLogic.toStopRecording(rows)) }
    func toggle(_ id: String) { toggleRecording([id]) }
    func focus(_ id: String) { sessions().first { $0.deviceId == id }?.focus() }
}

struct OperatorOverviewView: View {
    @ObservedObject var model: OperatorOverviewModel

    private func color(_ h: OverviewRow.Health) -> Color {
        switch h { case .good: return .green; case .warning: return .orange; case .bad: return .red }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Operator overview").font(.title3.bold())
                Spacer()
                // Recording is optional for events: the header only shows it while something records.
                if model.recordingCount > 0 { Button("Stop all recordings") { model.stopAll() } }
            }
            if model.rows.isEmpty {
                Text("No goggles are open").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rows) { r in
                        HStack(spacing: 10) {
                            Circle().fill(color(r.health)).frame(width: 12, height: 12)
                            Button { model.focus(r.id) } label: { Text(verbatim: r.name).font(.headline) }
                                .buttonStyle(.link)
                                .frame(width: 150, alignment: .leading)
                            Text(verbatim: r.status).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(verbatim: r.fps.map { "\($0) fps" } ?? "-").monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text(verbatim: r.battery.map { "\($0)%" } ?? "-").monospacedDigit().frame(width: 44, alignment: .trailing)
                            Button { model.toggle(r.id) } label: {
                                Text(verbatim: r.isRecording ? "● " + OverviewLogic.formatElapsed(r.elapsed) : L("Record"))
                                    .monospacedDigit().foregroundStyle(r.isRecording ? Color.red : Color.primary)
                            }
                            .disabled(!r.isLive && !r.isRecording)
                            .frame(width: 92)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            diskLine
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 200)
    }

    @ViewBuilder private var diskLine: some View {
        if let free = model.freeBytes, model.recordingCount > 0 {
            let level = model.diskLevel
            let hours = OverviewLogic.hoursLeft(freeBytes: free, recordings: model.recordingCount)
            HStack(spacing: 6) {
                Image(systemName: level == .ok ? "internaldrive" : "exclamationmark.triangle.fill")
                    .foregroundStyle(level == .critical ? Color.red : (level == .low ? Color.orange : Color.secondary))
                Text(verbatim: L("%@ free in %@", OverviewLogic.formatBytes(free), model.folderName))
                if level != .ok {
                    Text(verbatim: L("About %lld h of recording left at this rate", Int(hours))).foregroundStyle(level == .critical ? Color.red : Color.orange)
                }
            }
            .font(.caption)
        }
    }
}

enum OperatorOverviewWindow {
    private static var window: NSWindow?
    private static let model = OperatorOverviewModel()
    static var sessions: () -> [GogglesSession] = { [] }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        model.start(sessions: sessions)
        let host = NSHostingController(rootView: OperatorOverviewView(model: model))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = L("Operator overview")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 680, height: 320))
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            model.stop()
            window?.contentViewController = nil
            window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
#endif
