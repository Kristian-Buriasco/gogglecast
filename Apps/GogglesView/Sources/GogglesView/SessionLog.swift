import Foundation

/// Prefs for the per-session stats log.
enum SessionLogPrefs {
    static let enabledKey = "sessionLogEnabled"
    static let retentionDaysKey = "sessionLogRetentionDays"
    static let defaultRetentionDays = 30
    static let retentionRange = 1...365

    static var allKeys: [String] { [enabledKey, retentionDaysKey] }

    /// Default ON: a missing key counts as enabled.
    static func isEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: enabledKey) as? Bool ?? true
    }

    static func retentionDays(_ d: UserDefaults = .standard) -> Int {
        let v = d.object(forKey: retentionDaysKey) as? Int ?? defaultRetentionDays
        return min(max(v, retentionRange.lowerBound), retentionRange.upperBound)
    }

    /// ~/Library/Application Support/GogglesView/Logs
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GogglesView", isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
    }
}

enum SessionLogEvent: String, Codable, CaseIterable {
    case connected, streamLive, streamLost, recordingStarted, recordingStopped, marker, replaySaved, sessionEnd
}

/// One JSONL line: either a once-a-second `sample` or an `event`. Absent
/// values are omitted from the JSON. No secrets: paths are stored with the
/// home directory abbreviated to `~`, and the serial only appears in the file name.
struct SessionLogRow: Codable, Equatable {
    enum Kind: String, Codable { case sample, event }

    var t: Date
    var type: Kind
    var event: SessionLogEvent?
    var fps: Int?
    var kbps: Double?
    var latencyMs: Double?
    var drops: Int?
    var battery: Int?
    var width: Int?
    var height: Int?
    var recording: Bool?
    var path: String?
    var label: String?

    static func sample(at t: Date, fps: Int?, kbps: Double?, latencyMs: Double?, drops: Int?,
                       battery: Int?, width: Int?, height: Int?, recording: Bool) -> SessionLogRow {
        SessionLogRow(t: t, type: .sample, fps: fps, kbps: kbps.map(SessionLog.round1),
                      latencyMs: latencyMs.map(SessionLog.round1), drops: drops, battery: battery,
                      width: width, height: height, recording: recording)
    }

    static func event(_ e: SessionLogEvent, at t: Date, path: String? = nil, label: String? = nil) -> SessionLogRow {
        SessionLogRow(t: t, type: .event, event: e, path: path.map { SessionLog.abbreviateHome($0) }, label: label)
    }
}

struct SessionLogSummary: Equatable {
    var start: Date?
    var end: Date?
    var sampleCount = 0
    var minFps: Int?
    var avgFps: Double?
    var maxLatencyMs: Double?
    var batteryStart: Int?
    var batteryEnd: Int?
    var markerCount = 0
    /// Recording files (tilde paths) started or stopped during the session, in order.
    var recordings: [String] = []

    var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    /// Positive = drained. nil unless both ends were seen.
    var batteryDrop: Int? {
        guard let batteryStart, let batteryEnd else { return nil }
        return batteryStart - batteryEnd
    }
}

/// Pure formatting/parsing/rotation helpers (see SessionLogTests).
enum SessionLog {
    static let fileExtension = "jsonl"

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/", path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func expandHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }

    // MARK: Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One line, including the trailing newline.
    static func line(_ row: SessionLogRow) -> String {
        guard let data = try? encoder.encode(row), let s = String(data: data, encoding: .utf8) else { return "" }
        return s + "\n"
    }

    /// Undecodable lines (e.g. a half-written last line after a crash) are skipped.
    static func parse(_ text: String) -> [SessionLogRow] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(SessionLogRow.self, from: Data($0.utf8))
        }
    }

    // MARK: File naming / rotation

    /// "2026-10-03-142501-<serial>.jsonl" (local time). Serial, else deviceId, sanitized for a file name.
    static func fileName(start: Date, serial: String?, deviceId: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let raw = (serial?.isEmpty == false ? serial! : deviceId)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = String(raw.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
        return "\(f.string(from: start))-\(safe.isEmpty ? "unknown" : safe).\(fileExtension)"
    }

    /// Names of `.jsonl` logs last modified more than `days` days before `now`.
    static func filesToDelete(_ files: [(name: String, modified: Date)], now: Date, days: Int) -> [String] {
        guard days > 0 else { return [] }
        let cutoff = TimeInterval(days) * 86_400
        return files.filter {
            ($0.name as NSString).pathExtension.lowercased() == fileExtension && now.timeIntervalSince($0.modified) > cutoff
        }.map(\.name)
    }

    // MARK: Summary

    static func summary(_ rows: [SessionLogRow]) -> SessionLogSummary {
        var s = SessionLogSummary()
        s.start = rows.map(\.t).min()
        s.end = rows.map(\.t).max()
        var fpsTotal = 0
        var fpsCount = 0
        for row in rows.sorted(by: { $0.t < $1.t }) {
            if row.type == .sample {
                s.sampleCount += 1
                if let fps = row.fps {
                    s.minFps = min(s.minFps ?? fps, fps)
                    fpsTotal += fps
                    fpsCount += 1
                }
                if let l = row.latencyMs { s.maxLatencyMs = max(s.maxLatencyMs ?? l, l) }
                if let b = row.battery {
                    if s.batteryStart == nil { s.batteryStart = b }
                    s.batteryEnd = b
                }
            } else {
                if row.event == .marker { s.markerCount += 1 }
                if row.event == .recordingStarted || row.event == .recordingStopped,
                   let p = row.path, !s.recordings.contains(p) {
                    s.recordings.append(p)
                }
            }
        }
        if fpsCount > 0 { s.avgFps = Double(fpsTotal) / Double(fpsCount) }
        return s
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: CSV

    static let csvHeader = "timestamp,type,event,fps,bitrate_kbps,latency_ms,dropped_frames,battery_pct,width,height,recording,path,label"

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func csv(_ rows: [SessionLogRow]) -> String {
        let iso = ISO8601DateFormatter()
        func num(_ d: Double?) -> String { d.map { String(format: "%.1f", $0) } ?? "" }
        func int(_ i: Int?) -> String { i.map(String.init) ?? "" }
        let body = rows.map { r in
            [iso.string(from: r.t), r.type.rawValue, r.event?.rawValue ?? "", int(r.fps), num(r.kbps), num(r.latencyMs),
             int(r.drops), int(r.battery), int(r.width), int(r.height), r.recording.map { $0 ? "1" : "0" } ?? "",
             r.path ?? "", r.label ?? ""].map(csvField).joined(separator: ",")
        }
        return ([csvHeader] + body).joined(separator: "\n") + "\n"
    }
}
