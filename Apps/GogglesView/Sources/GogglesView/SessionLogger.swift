import Foundation
import Combine

extension Notification.Name {
    /// userInfo: ["label": String]. Posted by `Recorder.addMarker`.
    static let gogglesMarkerAdded = Notification.Name("GogglesMarkerAdded")
}

/// Append-only JSONL file. All I/O on one serial utility queue; each row is a
/// plain `write(2)` (FileHandle is unbuffered), so every row is on disk as
/// soon as it's written.
final class SessionLogWriter {
    private let queue = DispatchQueue(label: "sessionlog.writer", qos: .utility)
    private var handle: FileHandle?
    let url: URL

    init(url: URL) { self.url = url }

    func append(_ rows: [SessionLogRow]) {
        let text = rows.map(SessionLog.line).joined()
        guard !text.isEmpty else { return }
        queue.async {
            if self.handle == nil { self.open() }
            try? self.handle?.write(contentsOf: Data(text.utf8))
        }
    }

    func close() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}

/// Log folder housekeeping (I/O side of `SessionLog.filesToDelete`).
enum SessionLogStore {
    static func logFiles(in dir: URL = SessionLogPrefs.directory) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension.lowercased() == SessionLog.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // names start with the date: newest first
    }

    /// Permanently deletes logs older than the retention window; returns the count.
    @discardableResult
    static func prune(in dir: URL = SessionLogPrefs.directory, days: Int = SessionLogPrefs.retentionDays(),
                      now: Date = Date()) -> Int {
        let files = logFiles(in: dir).compactMap { u -> (name: String, modified: Date)? in
            guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (u.lastPathComponent, m)
        }
        let doomed = SessionLog.filesToDelete(files, now: now, days: days)
        for name in doomed { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        return doomed.count
    }

    private static var didPrune = false
    /// Once per process, off the main thread.
    static func pruneOnce() {
        guard !didPrune else { return }
        didPrune = true
        DispatchQueue.global(qos: .utility).async { prune() }
    }
}

/// Per-goggles session log. Attached by `GogglesSession`; stops (writing a
/// `sessionEnd` row) when the returned cancellable is released at teardown.
///
/// Rows before the stream first goes live are held in memory, so a window
/// that never shows video leaves no file. While live, one `sample` row per
/// second. Main-thread only (coordinator/decode publishers deliver there).
///
/// Recording/replay/marker notifications are attributed to this session when
/// their `object` is this session's `DecodeSession`; untagged (nil-object)
/// ones only when a single logger is running, since they can't be told apart.
final class SessionLogger {
    private static var runningCount = 0

    private let deviceId: String
    private weak var coordinator: GogglesConnectionCoordinator?
    private weak var decodeSession: DecodeSession?
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var writer: SessionLogWriter?
    private var pending: [SessionLogRow] = []
    private var lastKind: GogglesUIStateKind?
    private var isRecording = false
    private var stopped = false

    static func attach(coordinator: GogglesConnectionCoordinator, decodeSession: DecodeSession) -> AnyCancellable {
        let logger = SessionLogger(coordinator: coordinator, decodeSession: decodeSession)
        return AnyCancellable { logger.stop() }
    }

    private init(coordinator: GogglesConnectionCoordinator, decodeSession: DecodeSession) {
        self.deviceId = coordinator.deviceId
        self.coordinator = coordinator
        self.decodeSession = decodeSession
        Self.runningCount += 1
        SessionLogStore.pruneOnce()

        coordinator.$deviceInfo.compactMap { $0 }.first()
            .sink { [weak self] _ in self?.record(.event(.connected, at: Date())) }
            .store(in: &bag)

        coordinator.$uiState.sink { [weak self] state in self?.stateChanged(state.kind) }.store(in: &bag)

        let center = NotificationCenter.default
        let map: [(Notification.Name, SessionLogEvent)] = [
            (.gogglesRecordingStarted, .recordingStarted), (.gogglesRecordingStopped, .recordingStopped),
            (.gogglesReplaySaved, .replaySaved), (.gogglesMarkerAdded, .marker),
        ]
        for (name, event) in map {
            // recordingStopped/replaySaved are posted from writer completion queues.
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] n in self?.handle(n, as: event) }.store(in: &bag)
        }
    }

    private func stateChanged(_ kind: GogglesUIStateKind) {
        switch EventHookLogic.streamEvent(from: lastKind, to: kind) {
        case .streamLive?:
            record(.event(.streamLive, at: Date()))
            startSampling()
        case .streamLost?:
            stopSampling()
            record(.event(.streamLost, at: Date()))
        default: break
        }
        lastKind = kind
    }

    private func handle(_ n: Notification, as event: SessionLogEvent) {
        if let obj = n.object {
            guard (obj as AnyObject) === decodeSession else { return }
        } else if Self.runningCount != 1 {
            return
        }
        if event == .recordingStarted { isRecording = true }
        if event == .recordingStopped { isRecording = false }
        record(.event(event, at: Date(), path: n.userInfo?["path"] as? String, label: n.userInfo?["label"] as? String))
    }

    private func startSampling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let coordinator else { return }
        let stats = coordinator.stats
        let dims = decodeSession?.dimensions
        record(.sample(at: Date(), fps: stats?.fps, kbps: stats?.bitrateKbps, latencyMs: decodeSession?.latencyMs,
                       drops: stats?.cumulativeDrops, battery: coordinator.batteryPercent,
                       width: dims.map { Int($0.width) }, height: dims.map { Int($0.height) }, recording: isRecording))
    }

    private func record(_ row: SessionLogRow) {
        guard !stopped, SessionLogPrefs.isEnabled() else { return }
        if writer == nil {
            guard row.type == .sample || row.event == .streamLive else {
                if pending.count < 100 { pending.append(row) }
                return
            }
            let name = SessionLog.fileName(start: pending.first?.t ?? row.t, serial: coordinator?.deviceInfo?.serial, deviceId: deviceId)
            writer = SessionLogWriter(url: SessionLogPrefs.directory.appendingPathComponent(name))
        }
        writer?.append(pending + [row])
        pending.removeAll()
    }

    private func stop() {
        guard !stopped else { return }
        if writer != nil { record(.event(.sessionEnd, at: Date())) }
        stopped = true
        stopSampling()
        bag.removeAll()
        writer?.close()
        writer = nil
        Self.runningCount -= 1
    }
}
