import XCTest
@testable import GogglesView

final class SessionLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testPrefsDefaults() {
        let d = UserDefaults(suiteName: "SessionLogTests-\(UUID().uuidString)")!
        XCTAssertTrue(SessionLogPrefs.isEnabled(d))
        XCTAssertEqual(SessionLogPrefs.retentionDays(d), 30)
        d.set(false, forKey: SessionLogPrefs.enabledKey)
        d.set(9999, forKey: SessionLogPrefs.retentionDaysKey)
        XCTAssertFalse(SessionLogPrefs.isEnabled(d))
        XCTAssertEqual(SessionLogPrefs.retentionDays(d), 365)
        d.set(0, forKey: SessionLogPrefs.retentionDaysKey)
        XCTAssertEqual(SessionLogPrefs.retentionDays(d), 1)
        XCTAssertTrue(SessionLogPrefs.directory.path.hasSuffix("Application Support/GogglesView/Logs"))
    }

    func testDiagnosticsIncludesKeys() {
        for k in SessionLogPrefs.allKeys { XCTAssertTrue(DiagnosticsReport.settingsKeys.contains(k), k) }
    }

    func testLineRoundTripAndOmitsNil() {
        let row = SessionLogRow.sample(at: t0, fps: 60, kbps: 25_123.456, latencyMs: 31.26, drops: 2,
                                       battery: 80, width: 1920, height: 1080, recording: true)
        let line = SessionLog.line(row)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.contains("\"kbps\":25123.5"))
        XCTAssertTrue(line.contains("\"latencyMs\":31.3"))
        XCTAssertFalse(line.contains("event"))
        XCTAssertFalse(line.contains("path"))
        XCTAssertEqual(SessionLog.parse(line), [row])
    }

    func testParseSkipsGarbageAndPartialLines() {
        let a = SessionLogRow.event(.connected, at: t0)
        let b = SessionLogRow.event(.streamLive, at: t0.addingTimeInterval(1))
        let text = SessionLog.line(a) + "not json\n\n" + SessionLog.line(b) + "{\"t\":\"2026-"
        XCTAssertEqual(SessionLog.parse(text), [a, b])
    }

    func testEventPathAbbreviatesHome() {
        XCTAssertEqual(SessionLog.abbreviateHome("/Users/x/Movies/a.mov", home: "/Users/x"), "~/Movies/a.mov")
        XCTAssertEqual(SessionLog.abbreviateHome("/Users/xy/a.mov", home: "/Users/x"), "/Users/xy/a.mov")
        XCTAssertEqual(SessionLog.abbreviateHome("/tmp/a", home: "/"), "/tmp/a")
        XCTAssertEqual(SessionLog.expandHome("~/Movies/a.mov", home: "/Users/x"), "/Users/x/Movies/a.mov")
        XCTAssertEqual(SessionLog.expandHome("/abs", home: "/Users/x"), "/abs")
        let row = SessionLogRow.event(.recordingStarted, at: t0, path: NSHomeDirectory() + "/Movies/r.mov")
        XCTAssertEqual(row.path, "~/Movies/r.mov")
    }

    func testFileName() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SessionLog.fileName(start: t0, serial: "ABC123", deviceId: "dev", timeZone: utc),
                       "2023-11-14-221320-ABC123.jsonl")
        XCTAssertEqual(SessionLog.fileName(start: t0, serial: nil, deviceId: "bus 20/3", timeZone: utc),
                       "2023-11-14-221320-bus_20_3.jsonl")
        XCTAssertEqual(SessionLog.fileName(start: t0, serial: "", deviceId: "", timeZone: utc),
                       "2023-11-14-221320-unknown.jsonl")
    }

    func testRotation() {
        let now = t0
        let files: [(name: String, modified: Date)] = [
            ("old.jsonl", now.addingTimeInterval(-31 * 86_400)),
            ("new.jsonl", now.addingTimeInterval(-29 * 86_400)),
            ("old.txt", now.addingTimeInterval(-90 * 86_400)),
            ("OLD2.JSONL", now.addingTimeInterval(-40 * 86_400)),
        ]
        XCTAssertEqual(SessionLog.filesToDelete(files, now: now, days: 30), ["old.jsonl", "OLD2.JSONL"])
        XCTAssertEqual(SessionLog.filesToDelete(files, now: now, days: 0), [])
    }

    func testPruneOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessionlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("2020-01-01-000000-A.jsonl")
        let new = dir.appendingPathComponent("2026-01-01-000000-A.jsonl")
        try "x\n".write(to: old, atomically: true, encoding: .utf8)
        try "x\n".write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)], ofItemAtPath: old.path)
        XCTAssertEqual(SessionLogStore.prune(in: dir, days: 30), 1)
        XCTAssertEqual(SessionLogStore.logFiles(in: dir).map(\.lastPathComponent), [new.lastPathComponent])
    }

    func testSummary() {
        var rows: [SessionLogRow] = [
            .event(.connected, at: t0),
            .event(.streamLive, at: t0.addingTimeInterval(1)),
            .sample(at: t0.addingTimeInterval(2), fps: 60, kbps: 20_000, latencyMs: 30, drops: 0, battery: 90, width: 1920, height: 1080, recording: false),
            .sample(at: t0.addingTimeInterval(3), fps: 40, kbps: 18_000, latencyMs: 55, drops: 3, battery: 89, width: 1920, height: 1080, recording: true),
            .sample(at: t0.addingTimeInterval(4), fps: nil, kbps: nil, latencyMs: nil, drops: nil, battery: nil, width: nil, height: nil, recording: true),
            .event(.recordingStarted, at: t0.addingTimeInterval(3), path: "/tmp/a.mov"),
            .event(.marker, at: t0.addingTimeInterval(3), label: "M1"),
            .event(.recordingStopped, at: t0.addingTimeInterval(5), path: "/tmp/a.mov"),
            .sample(at: t0.addingTimeInterval(65), fps: 50, kbps: 1, latencyMs: 10, drops: 3, battery: 85, width: 1920, height: 1080, recording: false),
        ]
        rows.shuffle()
        let s = SessionLog.summary(rows)
        XCTAssertEqual(s.duration, 65)
        XCTAssertEqual(s.sampleCount, 4)
        XCTAssertEqual(s.minFps, 40)
        XCTAssertEqual(s.avgFps, 50)
        XCTAssertEqual(s.maxLatencyMs, 55)
        XCTAssertEqual(s.batteryStart, 90)
        XCTAssertEqual(s.batteryEnd, 85)
        XCTAssertEqual(s.batteryDrop, 5)
        XCTAssertEqual(s.markerCount, 1)
        XCTAssertEqual(s.recordings, ["/tmp/a.mov"])
        XCTAssertEqual(SessionLog.formatDuration(s.duration), "1:05")
        XCTAssertEqual(SessionLog.formatDuration(3725), "1:02:05")
    }

    func testEmptySummary() {
        let s = SessionLog.summary([])
        XCTAssertEqual(s.duration, 0)
        XCTAssertNil(s.avgFps)
        XCTAssertNil(s.batteryDrop)
    }

    func testCSV() {
        let rows: [SessionLogRow] = [
            .sample(at: t0, fps: 60, kbps: 1234.56, latencyMs: 20, drops: 1, battery: 77, width: 1280, height: 720, recording: false),
            .event(.marker, at: t0, label: "a, \"b\""),
        ]
        let lines = SessionLog.csv(rows).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4)  // header + 2 rows + trailing empty
        XCTAssertEqual(String(lines[0]), SessionLog.csvHeader)
        XCTAssertEqual(String(lines[1]), "2023-11-14T22:13:20Z,sample,,60,1234.6,20.0,1,77,1280,720,0,,")
        XCTAssertEqual(String(lines[2]), "2023-11-14T22:13:20Z,event,marker,,,,,,,,,,\"a, \"\"b\"\"\"")
        XCTAssertEqual(lines[1].split(separator: ",", omittingEmptySubsequences: false).count,
                       SessionLog.csvHeader.split(separator: ",").count)
    }
}
