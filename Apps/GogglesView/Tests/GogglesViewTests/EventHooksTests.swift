import XCTest
@testable import GogglesView

final class EventHooksTests: XCTestCase {
    func testPayloadJSON() throws {
        let s = EventHookLogic.payloadJSON(event: .screenshotSaved, fields: ["path": "/tmp/a.png"], date: Date(timeIntervalSince1970: 0))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "screenshotSaved")
        XCTAssertEqual(obj["path"] as? String, "/tmp/a.png")
        XCTAssertEqual(obj["timestamp"] as? String, "1970-01-01T00:00:00Z")
    }

    func testPayloadDropsNonJSONValues() throws {
        let s = EventHookLogic.payloadJSON(event: .streamLive, fields: ["bad": Date(), "n": 3])
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertNil(obj["bad"])
        XCTAssertEqual(obj["n"] as? Int, 3)
    }

    func testEnvironment() {
        let env = EventHookLogic.environment(base: ["A": "1"], event: .batteryLow, payload: "{}")
        XCTAssertEqual(env["GOGGLES_EVENT"], "batteryLow")
        XCTAssertEqual(env["GOGGLES_PAYLOAD"], "{}")
        XCTAssertEqual(env["A"], "1")
    }

    func testBatteryCrossing() {
        XCTAssertTrue(EventHookLogic.batteryCrossedBelow(previous: 15, current: 14, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 14, current: 13, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: nil, current: 5, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 50, current: nil, threshold: 15))
        XCTAssertFalse(EventHookLogic.batteryCrossedBelow(previous: 10, current: 90, threshold: 15))
    }

    func testStreamEvents() {
        XCTAssertEqual(EventHookLogic.streamEvent(from: .waitingForKeyframe, to: .live), .streamLive)
        XCTAssertEqual(EventHookLogic.streamEvent(from: .live, to: .stalled), .streamLost)
        XCTAssertNil(EventHookLogic.streamEvent(from: .live, to: .live))
        XCTAssertNil(EventHookLogic.streamEvent(from: nil, to: .noDevice))
    }

    func testWebhookValidation() {
        XCTAssertNotNil(EventHookLogic.validWebhook("https://example.com/x"))
        XCTAssertNil(EventHookLogic.validWebhook("file:///etc/passwd"))
        XCTAssertNil(EventHookLogic.validWebhook("example.com"))
    }

    // MARK: script path storage

    private final class MemoryBackend: SecretStore.Backend {
        var items: [String: String] = [:]
        func read(_ key: String) -> String? { items[key] }
        func write(_ value: String, _ key: String) -> Bool { items[key] = value; return true }
        func remove(_ key: String) { items[key] = nil }
    }

    private func withFakeStore(_ body: (MemoryBackend, UserDefaults) throws -> Void) rethrows {
        let savedBackend = SecretStore.backend, savedDefaults = SecretStore.defaults
        defer { SecretStore.backend = savedBackend; SecretStore.defaults = savedDefaults }
        let b = MemoryBackend()
        let d = UserDefaults(suiteName: "EventHooksTests-\(UUID().uuidString)")!
        SecretStore.backend = b; SecretStore.defaults = d
        try body(b, d)
    }

    func testScriptPathsMigrateToKeychainAndDefaultsAreThenIgnored() {
        withFakeStore { b, d in
            let key = EventHookConfig.scriptKey(.recordingStarted)
            d.set("/usr/bin/true", forKey: key)
            EventHookConfig.migrateScriptPaths()
            XCTAssertEqual(b.items[key], "/usr/bin/true")
            XCTAssertNil(d.string(forKey: key), "plain-text copy removed")
            XCTAssertNotNil(b.items[EventHookConfig.migratedKey])
            XCTAssertEqual(EventHookConfig.script(.recordingStarted), "/usr/bin/true")

            // Another process planting a path in UserDefaults afterwards must not take effect.
            d.set("/tmp/evil.sh", forKey: EventHookConfig.scriptKey(.screenshotSaved))
            XCTAssertEqual(EventHookConfig.script(.screenshotSaved), "")
            XCTAssertEqual(EventHookConfig.script(.recordingStarted), "/usr/bin/true")

            // Settings-UI writes go to the Keychain.
            EventHookConfig.setScript("/usr/bin/false", for: .screenshotSaved)
            XCTAssertEqual(EventHookConfig.script(.screenshotSaved), "/usr/bin/false")
            XCTAssertEqual(b.items[EventHookConfig.scriptKey(.screenshotSaved)], "/usr/bin/false")
            EventHookConfig.setScript("", for: .screenshotSaved)
            XCTAssertEqual(EventHookConfig.script(.screenshotSaved), "")
        }
    }

    // MARK: execution

    private func makeScript(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("hook.sh")
        try ("#!/bin/sh\n" + body).write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f
    }

    func testScriptReceivesArgumentStdinAndEnvironment() throws {
        let f = try makeScript("echo \"arg=$1 env=$GOGGLES_EVENT\"; cat\n")
        defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let run = EventBus.execute(path: f.path, event: .replaySaved, json: "{\"x\":1}", timeout: 5)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertTrue(run.output.contains("arg=replaySaved env=replaySaved"), run.output)
        XCTAssertTrue(run.output.contains("{\"x\":1}"), run.output)
        let failing = try makeScript("exit 3\n")
        defer { try? FileManager.default.removeItem(at: failing.deletingLastPathComponent()) }
        XCTAssertEqual(EventBus.execute(path: failing.path, event: .batteryLow, json: "{}", timeout: 5).exitCode, 3)
        XCTAssertNil(EventBus.execute(path: "/nonexistent/x", event: .batteryLow, json: "{}", timeout: 1).exitCode)
    }

    func testTimeoutKillsTheWholeProcessGroup() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("hook-child-\(UUID().uuidString).pid")
        // The script starts a long-running child, records its pid and then waits itself.
        let f = try makeScript("sleep 60 &\necho $! > '\(pidFile.path)'\nwait\n")
        defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()); try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        let run = EventBus.execute(path: f.path, event: .streamLost, json: "{}", timeout: 1)
        XCTAssertNil(run.exitCode)
        XCTAssertTrue(run.output.contains("timed out"), run.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Give the kernel a moment to reap, then the grandchild must be gone.
        var alive = true
        for _ in 0..<20 { if kill(pid, 0) != 0 { alive = false; break }; usleep(100_000) }
        XCTAssertFalse(alive, "grandchild \(pid) survived the timeout")
    }
}
