import Foundation

// Operator overview: one window with a row per open goggles (name, state, fps, battery, issues,
// outputs). For events with several goggles, where walking through every window to see who is live is
// too slow. Recording controls only appear while something records.

struct OverviewRow: Equatable, Identifiable {
    typealias Health = FeedHealth

    let id: String          // deviceId
    var name: String
    var status: String
    var health: FeedHealth
    var isLive: Bool
    var fps: Int?
    var battery: Int?
    var isRecording: Bool
    var elapsed: TimeInterval
    var issues: [FeedIssue] = []
    var outputs: [OutputChip] = []
}

enum OverviewLogic {
    static func health(for kind: GogglesUIStateKind) -> FeedHealth {
        switch kind {
        case .live: return .good
        case .claiming, .resolving, .handshaking, .waitingForKeyframe, .stalled: return .warning
        case .noHelper, .noDevice, .claimFailed: return .bad
        }
    }

    /// Windows to toggle for "Stop all": everything that is recording.
    static func toStopRecording(_ rows: [OverviewRow]) -> [String] { rows.filter(\.isRecording).map(\.id) }

    /// The worst health over all rows; nil when nothing is open.
    static func worst(_ rows: [OverviewRow]) -> FeedHealth? { rows.map(\.health).max() }

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

    /// The text for a row's output chips, for example "SRT UDP" (waiting ones in brackets).
    static func outputSummary(_ chips: [OutputChip]) -> String {
        let on = chips.filter { $0.state != .off }
        return on.isEmpty ? "-" : on.map { c in
            switch c.state { case .waiting: return "(\(c.name))"; case .error: return "\(c.name)!"; default: return c.name }
        }.joined(separator: " ")
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import Combine

/// The shared status of every open goggles, refreshed once a second. Owned by the app, so the menu-bar
/// icon and the web status page keep working with the overview window closed.
final class EventStatus: ObservableObject {
    static let shared = EventStatus()

    @Published private(set) var rows: [OverviewRow] = []
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var folderName = ""

    private var sessions: () -> [GogglesSession] = { [] }
    private var timer: Timer?
    private var watches: [String: PictureWatch] = [:]
    private var pictures: [String: PictureState] = [:]
    private var lastSample: [String: Date] = [:]
    static let sampleInterval: TimeInterval = 2

    func install(sessions: @escaping () -> [GogglesSession]) {
        self.sessions = sessions
        timer?.invalidate()
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var recordingCount: Int { rows.filter(\.isRecording).count }
    var diskLevel: OverviewLogic.DiskLevel { OverviewLogic.diskLevel(freeBytes: freeBytes, recordings: recordingCount) }
    var worst: FeedHealth? { OverviewLogic.worst(rows) }

    func refresh() {
        let now = Date()
        let all = sessions()
        let names = Dictionary(uniqueKeysWithValues: ProgramOutputController.shared.available.map { ($0.id, $0.name) })
        let ids = Set(all.map(\.deviceId))
        for k in Set(watches.keys).subtracting(ids) { watches[k] = nil; pictures[k] = nil; lastSample[k] = nil }

        let next: [OverviewRow] = all.map { s in
            let c = s.coordinator
            let kind = c.uiState.kind
            let live = kind == .live
            if live {
                if now.timeIntervalSince(lastSample[s.deviceId] ?? .distantPast) >= Self.sampleInterval {
                    lastSample[s.deviceId] = now
                    let sample = s.decodeSession.latestDecodedFrame().flatMap { PictureWatch.sample($0) }
                    var w = watches[s.deviceId] ?? PictureWatch()
                    pictures[s.deviceId] = w.observe(sample, sequence: s.decodeSession.decodedSequence(), now: now)
                    watches[s.deviceId] = w
                }
            } else {
                watches[s.deviceId] = nil; pictures[s.deviceId] = nil; lastSample[s.deviceId] = nil
            }
            let issues = EventRules.issues(live: live, battery: c.batteryPercent, picture: pictures[s.deviceId] ?? .unknown)
            let rec = SessionControlBoard.shared.recorder(for: s.decodeSession)
            return OverviewRow(
                id: s.deviceId, name: names[s.deviceId] ?? s.label,
                status: MenuBarController.displayText(for: c.uiState, stats: c.stats),
                health: EventRules.combine(connection: OverviewLogic.health(for: kind), issues: issues), isLive: live,
                fps: c.stats?.fps, battery: c.batteryPercent,
                isRecording: rec?.isRecording ?? false, elapsed: rec?.elapsed ?? 0,
                issues: issues, outputs: SessionControlBoard.shared.outputChips(for: s.decodeSession))
        }
        let before = worst
        if next != rows {
            rows = next
            WebStatusStore.set(EventStatusJSON.data(rows: next, now: now))
        }
        if before != worst { NotificationCenter.default.post(name: .eventStatusChanged, object: nil) }
        let folder = RecordingPrefs.directory
        freeBytes = Recorder.volumeCapacity(at: folder)
        folderName = folder.lastPathComponent
    }

    private func sessionsMatching(_ ids: [String]) -> [GogglesSession] { sessions().filter { ids.contains($0.deviceId) } }

    func stopAllRecordings() {
        for s in sessionsMatching(OverviewLogic.toStopRecording(rows)) {
            NotificationCenter.default.post(name: .gogglesToggleRecording, object: s.decodeSession)
        }
    }

    func toggleRecording(_ id: String) {
        for s in sessionsMatching([id]) { NotificationCenter.default.post(name: .gogglesToggleRecording, object: s.decodeSession) }
    }

    func focus(_ id: String) { sessionsMatching([id]).first?.focus() }
    func startAllOutputs() { NotificationCenter.default.post(name: .gogglesStartAllOutputs, object: nil) }
    func stopAllOutputs() { NotificationCenter.default.post(name: .gogglesStopAllOutputs, object: nil) }
}

private func healthColor(_ h: FeedHealth) -> Color {
    switch h { case .good: return .green; case .warning: return .orange; case .bad: return .red }
}

struct OperatorOverviewView: View {
    @ObservedObject var status: EventStatus
    @State private var big = false
    @AppStorage(EventOutputKind.srt.prefKey) private var useSRT = true
    @AppStorage(EventOutputKind.udp.prefKey) private var useUDP = false
    @AppStorage(EventOutputKind.ndi.prefKey) private var useNDI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if status.rows.isEmpty {
                Text("No goggles are open").foregroundStyle(.secondary).padding(.vertical, 20)
            } else if big {
                bigGrid
            } else {
                list
            }
            if !big { diskLine }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 200)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Operator overview").font(.title3.bold())
            Spacer()
            Toggle("SRT", isOn: $useSRT).toggleStyle(.checkbox)
            Toggle("UDP", isOn: $useUDP).toggleStyle(.checkbox)
            Toggle("NDI", isOn: $useNDI).toggleStyle(.checkbox)
            Button("Start all outputs") { status.startAllOutputs() }
            Button("Stop all outputs") { status.stopAllOutputs() }
            if status.recordingCount > 0 { Button("Stop all recordings") { status.stopAllRecordings() } }
            Button(big ? L("List") : L("Big view")) { big.toggle() }
            Button { OperatorOverviewWindow.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(L("Full screen"))
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(status.rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Circle().fill(healthColor(r.health)).frame(width: 12, height: 12)
                        Button { status.focus(r.id) } label: { Text(verbatim: r.name).font(.headline) }
                            .buttonStyle(.link).frame(width: 150, alignment: .leading)
                        Text(verbatim: r.status).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(verbatim: OverviewLogic.outputSummary(r.outputs)).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text(verbatim: r.fps.map { "\($0) fps" } ?? "-").monospacedDigit().frame(width: 60, alignment: .trailing)
                        Text(verbatim: r.battery.map { "\($0)%" } ?? "-").monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button { status.toggleRecording(r.id) } label: {
                            Text(verbatim: r.isRecording ? "● " + OverviewLogic.formatElapsed(r.elapsed) : L("Record"))
                                .monospacedDigit().foregroundStyle(r.isRecording ? Color.red : Color.primary)
                        }
                        .disabled(!r.isLive && !r.isRecording).frame(width: 92)
                    }
                    if !r.issues.isEmpty {
                        Text(verbatim: r.issues.map(\.text).joined(separator: " · "))
                            .font(.caption.bold()).foregroundStyle(healthColor(max(r.health, .warning))).padding(.leading, 22)
                    }
                }
                .padding(.vertical, 6)
                .background(r.health == .bad ? Color.red.opacity(0.12) : Color.clear)
                Divider()
            }
        }
    }

    private var bigGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(status.rows) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: r.name).font(.system(size: 40, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(verbatim: r.status).font(.system(size: 20)).lineLimit(1)
                        HStack {
                            Text(verbatim: r.fps.map { "\($0) fps" } ?? "-")
                            Spacer()
                            Text(verbatim: r.battery.map { "\($0)%" } ?? "-")
                        }
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        Text(verbatim: r.issues.isEmpty ? " " : r.issues.map(\.text).joined(separator: " · "))
                            .font(.system(size: 18, weight: .bold)).lineLimit(2)
                        Text(verbatim: OverviewLogic.outputSummary(r.outputs)).font(.system(size: 16)).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                    .background(healthColor(r.health).opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    @ViewBuilder private var diskLine: some View {
        if let free = status.freeBytes, status.recordingCount > 0 {
            let level = status.diskLevel
            let hours = OverviewLogic.hoursLeft(freeBytes: free, recordings: status.recordingCount)
            HStack(spacing: 6) {
                Image(systemName: level == .ok ? "internaldrive" : "exclamationmark.triangle.fill")
                    .foregroundStyle(level == .critical ? Color.red : (level == .low ? Color.orange : Color.secondary))
                Text(verbatim: L("%@ free in %@", OverviewLogic.formatBytes(free), status.folderName))
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

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: OperatorOverviewView(status: EventStatus.shared))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = L("Operator overview")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.collectionBehavior = [.fullScreenPrimary]
        w.setContentSize(NSSize(width: 760, height: 360))
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            window?.contentViewController = nil
            window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func toggleFullScreen() { window?.toggleFullScreen(nil) }
}
#endif
