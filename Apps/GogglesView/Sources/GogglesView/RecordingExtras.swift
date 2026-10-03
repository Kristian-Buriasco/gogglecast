import Foundation

/// Pure logic + prefs for auto-split, loop retention and auto-delete (unit-tested).
enum RecordingExtras {
    static let splitMinutesKey = "recordingSplitMinutes"
    static let splitMegabytesKey = "recordingSplitMegabytes"
    static let loopKeepMinutesKey = "recordingLoopKeepMinutes"
    static let autoDeleteDaysKey = "recordingAutoDeleteDays"

    static var allKeys: [String] { [splitMinutesKey, splitMegabytesKey, loopKeepMinutesKey, autoDeleteDaysKey] }

    /// Limits for one recording session; nil = unlimited.
    struct SplitLimits: Equatable {
        var maxSeconds: TimeInterval?
        var maxBytes: Int64?
        var loopKeepSeconds: TimeInterval?
    }

    /// Loop mode overrides the time limit with max(1, keep/6) minutes per segment.
    static func limits(splitMinutes: Int, splitMegabytes: Int, loopKeepMinutes: Int) -> SplitLimits {
        let loop = max(0, loopKeepMinutes)
        var minutes = min(max(0, splitMinutes), 120)
        if loop > 0 { minutes = max(1, loop / 6) }
        return SplitLimits(
            maxSeconds: minutes > 0 ? TimeInterval(minutes * 60) : nil,
            maxBytes: splitMegabytes > 0 ? Int64(splitMegabytes) * 1_000_000 : nil,
            loopKeepSeconds: loop > 0 ? TimeInterval(loop * 60) : nil)
    }

    static func currentLimits(_ d: UserDefaults = .standard) -> SplitLimits {
        limits(splitMinutes: d.integer(forKey: splitMinutesKey),
               splitMegabytes: d.integer(forKey: splitMegabytesKey),
               loopKeepMinutes: d.integer(forKey: loopKeepMinutesKey))
    }

    static func shouldSplit(elapsed: TimeInterval, bytes: Int64, limits: SplitLimits) -> Bool {
        if let s = limits.maxSeconds, elapsed >= s { return true }
        if let b = limits.maxBytes, bytes >= b { return true }
        return false
    }

    /// Part 1 keeps the base name; later parts get `-partN` before the extension.
    static func partURL(base: URL, part: Int) -> URL {
        guard part > 1 else { return base }
        let ext = base.pathExtension
        let name = base.deletingPathExtension().lastPathComponent + "-part\(part)"
        return base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// How many oldest segments to delete so the total is <= keep. The newest is never deleted.
    static func segmentsToDelete(durations: [TimeInterval], keepSeconds: TimeInterval) -> Int {
        var total = durations.reduce(0, +)
        var n = 0
        while n < durations.count - 1 && total > keepSeconds {
            total -= durations[n]; n += 1
        }
        return n
    }

    // MARK: Auto-delete

    static let deletableExtensions: Set<String> = ["mov", "mp4", "json"]

    static func isAutoDeleteCandidate(fileName: String, prefix: String, modified: Date, now: Date, days: Int) -> Bool {
        guard days > 0, fileName.hasPrefix(prefix + "-"),
              deletableExtensions.contains((fileName as NSString).pathExtension.lowercased()) else { return false }
        return now.timeIntervalSince(modified) > TimeInterval(days) * 86_400
    }

    /// Moves old recordings to the Trash; returns the trashed count.
    @discardableResult
    static func autoDeleteOld(in dir: URL = RecordingPrefs.directory, prefix: String = RecordingPrefs.prefix,
                              days: Int = UserDefaults.standard.integer(forKey: autoDeleteDaysKey),
                              now: Date = Date()) -> Int {
        guard days > 0, let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return 0 }
        var n = 0
        for u in items {
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let m = v?.contentModificationDate,
                  isAutoDeleteCandidate(fileName: u.lastPathComponent, prefix: prefix, modified: m, now: now, days: days)
            else { continue }
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { n += 1 }
        }
        return n
    }

    private static var didRunLaunchCleanup = false
    /// Once per process; called from `Recorder.init` (the recorder is created at launch).
    static func runLaunchCleanupOnce() {
        guard !didRunLaunchCleanup else { return }
        didRunLaunchCleanup = true
        DispatchQueue.global(qos: .utility).async { autoDeleteOld() }
    }
}

/// A timestamped note on a recording.
struct RecordingMarker: Codable, Equatable {
    var t: Double
    var label: String
}

enum RecordingMarkers {
    static let defaultLabels = ["Highlight", "Crash", "Near miss", "Good line", "Landing", "Issue"]

    static func sidecarURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("markers.json")
    }

    static func encode(_ markers: [RecordingMarker]) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(markers)
    }
}
