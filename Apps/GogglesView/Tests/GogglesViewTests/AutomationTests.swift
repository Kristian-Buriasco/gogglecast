import XCTest
@testable import GogglesView

final class AutomationTests: XCTestCase {
    private func parse(_ s: String) -> AutomationRequest? {
        guard let url = URL(string: s) else { return nil }
        return AutomationURLParser.parse(url)
    }

    func testAllCommands() {
        let expected: [(String, AutomationCommand)] = [
            ("record/start", .startRecording), ("record/stop", .stopRecording),
            ("record/toggle", .toggleRecording), ("replay/save", .saveReplay),
            ("screenshot", .screenshot), ("screenshot/copy", .copyFrame), ("freeze/toggle", .toggleFreeze),
            ("marker", .addMarker(label: "Marker")), ("stream/start", .startStream),
            ("stream/stop", .stopStream), ("window/show", .showWindow),
            ("race/on", .raceOn), ("race/off", .raceOff), ("race/toggle", .raceToggle),
        ]
        XCTAssertEqual(expected.map(\.0), AutomationURLParser.examplePaths)
        for (path, cmd) in expected {
            XCTAssertEqual(parse("gogglesview://\(path)"), AutomationRequest(command: cmd, device: nil), path)
        }
    }

    func testCaseInsensitiveAndTrailingSlash() {
        XCTAssertEqual(parse("GogglesView://Record/Toggle/")?.command, .toggleRecording)
        XCTAssertEqual(parse("gogglesview:record/start")?.command, .startRecording)
    }

    func testDeviceParameter() {
        XCTAssertEqual(parse("gogglesview://record/start?device=ABC123"), AutomationRequest(command: .startRecording, device: "ABC123"))
        XCTAssertNil(parse("gogglesview://record/start?device="))
        XCTAssertNil(parse("gogglesview://record/start?device=a%20b"))
        XCTAssertNil(parse("gogglesview://record/start?device=../etc"))
        XCTAssertNil(parse("gogglesview://record/start?device=x;rm%20-rf"))
        XCTAssertNil(parse("gogglesview://record/start?device=A&device=B"))
        XCTAssertNil(parse("gogglesview://record/start?device=" + String(repeating: "a", count: 65)))
    }

    func testMarkerLabelSanitized() {
        XCTAssertEqual(parse("gogglesview://marker?label=Lap%201")?.command, .addMarker(label: "Lap 1"))
        XCTAssertEqual(parse("gogglesview://marker?label=%0A%09")?.command, .addMarker(label: "Marker"))
        XCTAssertEqual(parse("gogglesview://marker?label=a%0Ab")?.command, .addMarker(label: "ab"))
        let long = String(repeating: "x", count: 200)
        if case .addMarker(let label)? = parse("gogglesview://marker?label=\(long)")?.command {
            XCTAssertEqual(label.count, AutomationURLParser.maxLabelLength)
        } else { XCTFail() }
    }

    func testMalformedIgnored() {
        for s in [
            "gogglesview://", "gogglesview://record", "gogglesview://record/explode",
            "gogglesview://record/start/now", "gogglesview://record/start#frag",
            "gogglesview://user:pw@record/start", "gogglesview://record:8080/start",
            "http://record/start", "file:///tmp/x", "gogglesview://screenshot/../../etc/passwd",
            "gogglesview://shell/run?cmd=ls", "gogglesview://stream/start/evil.example.com",
            "gogglesview://%2Fbin%2Fsh",
        ] {
            XCTAssertNil(parse(s), s)
        }
    }

    func testUnknownParamsIgnoredNotInterpreted() {
        // host/port/path never come from the URL: extra params are dropped.
        XCTAssertEqual(parse("gogglesview://stream/start?host=evil.example.com&port=1&path=/tmp/x"),
                       AutomationRequest(command: .startStream, device: nil))
    }

    func testTargeting() {
        struct S: Equatable { let serial: String?; let id: String }
        let a = S(serial: "SER1", id: "dev-a"), b = S(serial: nil, id: "dev-b")
        let ids: (S) -> [String?] = { [$0.serial, $0.id] }
        XCTAssertEqual(AutomationTargeting.pick(device: "ser1", sessions: [a, b], frontmost: b, identifiers: ids), a)
        XCTAssertEqual(AutomationTargeting.pick(device: "DEV-B", sessions: [a, b], frontmost: a, identifiers: ids), b)
        XCTAssertNil(AutomationTargeting.pick(device: "nope", sessions: [a, b], frontmost: a, identifiers: ids))
        XCTAssertEqual(AutomationTargeting.pick(device: nil, sessions: [a, b], frontmost: b, identifiers: ids), b)
        XCTAssertEqual(AutomationTargeting.pick(device: nil, sessions: [a], frontmost: nil, identifiers: ids), a)
        XCTAssertNil(AutomationTargeting.pick(device: nil, sessions: [a, b], frontmost: nil, identifiers: ids))
    }

    func testPrefsDefaultOnAndDisabledGate() {
        let d = UserDefaults(suiteName: "AutomationTests")!
        d.removePersistentDomain(forName: "AutomationTests")
        XCTAssertTrue(AutomationPrefs.enabled(d))
        d.set(false, forKey: AutomationPrefs.enabledKey)
        XCTAssertFalse(AutomationPrefs.enabled(d))
        d.removePersistentDomain(forName: "AutomationTests")
    }

    func testDiagnosticsIncludesAutomationKey() {
        XCTAssertTrue(DiagnosticsReport.settingsKeys.contains(AutomationPrefs.enabledKey))
        XCTAssertTrue(DiagnosticsReport.settingsKeys.contains(AutomationPrefs.urlEnabledKey))
    }

    func testURLCommandsDefaultOff() {
        let d = UserDefaults(suiteName: "AutomationTests.url")!
        d.removePersistentDomain(forName: "AutomationTests.url")
        defer { d.removePersistentDomain(forName: "AutomationTests.url") }
        XCTAssertFalse(AutomationPrefs.urlEnabled(d))
        d.set(true, forKey: AutomationPrefs.urlEnabledKey)
        XCTAssertTrue(AutomationPrefs.urlEnabled(d))
    }

    func testGateNotifiesOnceWhileOffThenIgnores() {
        var g = AutomationURLGate()
        XCTAssertEqual(g.decide(urlEnabled: false), .ignoredNotify)
        XCTAssertEqual(g.decide(urlEnabled: false), .ignored)
        XCTAssertEqual(g.decide(urlEnabled: false), .ignored)
    }

    func testGateRateLimitsToAFewPerSecond() {
        var g = AutomationURLGate()
        let t = Date(timeIntervalSince1970: 5000)
        for i in 0..<AutomationURLGate.maxPerWindow {
            XCTAssertEqual(g.decide(urlEnabled: true, now: t.addingTimeInterval(Double(i) * 0.1)), .allowed)
        }
        XCTAssertEqual(g.decide(urlEnabled: true, now: t.addingTimeInterval(0.5)), .rateLimited)
        XCTAssertEqual(g.decide(urlEnabled: true, now: t.addingTimeInterval(1.05)), .allowed) // oldest aged out
    }

    func testHandleURLHonoursSwitchAndAnnounces() {
        let d = UserDefaults(suiteName: "AutomationTests.handle")!
        d.removePersistentDomain(forName: "AutomationTests.handle")
        defer { d.removePersistentDomain(forName: "AutomationTests.handle") }
        let c = AutomationController()
        var notices: [String] = []
        let url = URL(string: "gogglesview://record/toggle")!
        // Off: ignored, one notice for the first command only.
        XCTAssertEqual(c.handle(url: url, defaults: d, notify: { notices.append($0) }), .disabled)
        XCTAssertEqual(c.handle(url: url, defaults: d, notify: { notices.append($0) }), .disabled)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Allow gogglesview:// URL commands"))
        // On: each command is announced, and the 4th within a second is dropped.
        d.set(true, forKey: AutomationPrefs.urlEnabledKey)
        notices = []
        for _ in 0..<AutomationURLGate.maxPerWindow {
            XCTAssertEqual(c.handle(url: url, defaults: d, notify: { notices.append($0) }), .noTarget) // no window open in tests
        }
        XCTAssertEqual(notices.count, AutomationURLGate.maxPerWindow)
        XCTAssertNil(c.handle(url: url, defaults: d, notify: { notices.append($0) }))
        XCTAssertEqual(notices.count, AutomationURLGate.maxPerWindow)
        // AppleScript path (`perform`) is not gated by the URL switch.
        d.set(false, forKey: AutomationPrefs.urlEnabledKey)
        XCTAssertNotEqual(c.perform(AutomationRequest(command: .toggleRecording, device: nil)), .disabled)
    }
}
