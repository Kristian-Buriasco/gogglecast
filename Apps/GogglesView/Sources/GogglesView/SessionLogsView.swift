#if canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionLogEntry: Identifiable {
    let url: URL
    let summary: SessionLogSummary
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

final class SessionLogsModel: ObservableObject {
    @Published private(set) var entries: [SessionLogEntry] = []
    @Published var error: String?

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            SessionLogStore.prune()
            let list = SessionLogStore.logFiles().map { u in
                SessionLogEntry(url: u, summary: SessionLog.summary(Self.rows(u)))
            }
            DispatchQueue.main.async { self.entries = list }
        }
    }

    static func rows(_ url: URL) -> [SessionLogRow] {
        (try? String(contentsOf: url, encoding: .utf8)).map(SessionLog.parse) ?? []
    }

    func exportCSV(_ entry: SessionLogEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = entry.name + ".csv"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do { try SessionLog.csv(Self.rows(entry.url)).write(to: dest, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ entry: SessionLogEntry) {
        do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) }
        catch { self.error = error.localizedDescription }
        reload()
    }
}

/// Past session logs, newest first.
struct SessionLogsView: View {
    @StateObject private var model = SessionLogsModel()

    var body: some View {
        Group {
            if model.entries.isEmpty {
                Text("No session logs in \(SessionLog.abbreviateHome(SessionLogPrefs.directory.path))").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    SessionLogRowView(entry: entry, model: model)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .toolbar {
            Button { NSWorkspace.shared.open(SessionLogsWindowController.ensuredDirectory()) } label: { Image(systemName: "folder") }
                .help("Open logs folder")
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
        .onAppear { model.reload() }
        .alert("Session log", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct SessionLogRowView: View {
    let entry: SessionLogEntry
    let model: SessionLogsModel

    var body: some View {
        let s = entry.summary
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Export CSV…") { model.exportCSV(entry) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Delete", role: .destructive) { model.delete(entry) }
            }
            .controlSize(.small)
            Text(details(s)).font(.caption).foregroundStyle(.secondary)
            ForEach(existingRecordings(s), id: \.self) { path in
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Label((path as NSString).lastPathComponent, systemImage: "film")
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func details(_ s: SessionLogSummary) -> String {
        var parts = [SessionLog.formatDuration(s.duration)]
        if let avg = s.avgFps, let min = s.minFps { parts.append(String(format: "avg %.0f fps (min %d)", avg, min)) }
        if let l = s.maxLatencyMs { parts.append(String(format: "max %.0f ms", l)) }
        if let a = s.batteryStart, let b = s.batteryEnd { parts.append("battery \(a)% → \(b)%") }
        if s.markerCount > 0 { parts.append("\(s.markerCount) marker\(s.markerCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func existingRecordings(_ s: SessionLogSummary) -> [String] {
        s.recordings.map { SessionLog.expandHome($0) }.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

final class SessionLogsWindowController: NSObject {
    static let shared = SessionLogsWindowController()
    private var window: NSWindow?

    static func ensuredDirectory() -> URL {
        let dir = SessionLogPrefs.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SessionLogsView()))
            w.title = "Session Logs"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 680, height: 440))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Insert in the Advanced tab of SettingsView.
struct SessionLogSettingsSection: View {
    @AppStorage(SessionLogPrefs.enabledKey) private var enabled = true
    @AppStorage(SessionLogPrefs.retentionDaysKey) private var retentionDays = SessionLogPrefs.defaultRetentionDays

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session log").font(.headline)
            Toggle("Log stream stats while live", isOn: $enabled)
            Text("Once a second per goggles: fps, bitrate, latency, dropped frames, goggles battery, resolution, recording state, plus connect/stream/recording/marker/replay events. Saved as JSONL; no drone telemetry.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Keep logs for \(retentionDays) day\(retentionDays == 1 ? "" : "s")", value: $retentionDays,
                    in: SessionLogPrefs.retentionRange)
            HStack {
                Button("Open logs folder") { NSWorkspace.shared.open(SessionLogsWindowController.ensuredDirectory()) }
                Button("Session logs…") { SessionLogsWindowController.shared.show() }
            }
            // Separates this section from the next one in the Advanced tab.
            Divider().padding(.top, 6)
        }
    }
}
#endif
