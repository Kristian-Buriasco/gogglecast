import XCTest
import ServiceManagement
@testable import GogglesView

private final class StubPowerSession: PowerAwareSession {
    var events: [String] = []
    func powerWillSleep() { events.append("sleep") }
    func powerDidWake() { events.append("wake") }
}

final class PowerEventsTests: XCTestCase {
    func testSleepNotifiesEverySessionAndWakeReconnectsAfterDelay() {
        let center = NotificationCenter()
        var scheduled: [(TimeInterval, () -> Void)] = []
        let events = PowerEvents(center: center, schedule: { scheduled.append(($0, $1)) })
        let a = StubPowerSession(), b = StubPowerSession()
        events.install(sessions: { [a, b] })

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(a.events, ["sleep"])
        XCTAssertEqual(b.events, ["sleep"])

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(a.events, ["sleep"], "no reconnect before the delay")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].0, 1, accuracy: 0.001)
        scheduled[0].1()
        XCTAssertEqual(a.events, ["sleep", "wake"])
        XCTAssertEqual(b.events, ["sleep", "wake"])
    }

    func testSessionsClosedDuringTheWakeDelayAreSkipped() {
        let center = NotificationCenter()
        var scheduled: [() -> Void] = []
        let events = PowerEvents(center: center, schedule: { scheduled.append($1) })
        let a = StubPowerSession()
        var open: [PowerAwareSession] = [a]
        events.install(sessions: { open })
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        open = []
        scheduled.forEach { $0() }
        XCTAssertTrue(a.events.isEmpty)
    }

    func testInstallIsIdempotent() {
        let center = NotificationCenter()
        let events = PowerEvents(center: center, schedule: { _, _ in })
        let a = StubPowerSession()
        events.install(sessions: { [a] })
        events.install(sessions: { [a] })
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(a.events, ["sleep"])
    }

    func testSignalPolicyStaysQuietAcrossSleep() {
        // What `suspendForSleep` does to the policy: no alert while quiet, normal again after a picture.
        let t0 = Date(timeIntervalSince1970: 1_000)
        var p = SignalAlertPolicy(config: .init(threshold: 3, repeatInterval: 5, restoreStability: 2))
        _ = p.frameArrived(at: t0)
        p.userDisconnected()
        XCTAssertNil(p.tick(now: t0.addingTimeInterval(60)))
        XCTAssertNil(p.frameArrived(at: t0.addingTimeInterval(70)), "no restored notice after the sleep")
        XCTAssertEqual(p.tick(now: t0.addingTimeInterval(73)), .lost)
    }
}

final class PowerActivityKeeperTests: XCTestCase {
    private final class Token: NSObject {}

    func testHoldsOnlyWhileBusy() {
        var busy = false
        var begun = 0, ended = 0
        let keeper = PowerActivityKeeper(isBusy: { busy }, begin: { _ in begun += 1; return Token() }, end: { _ in ended += 1 })
        keeper.evaluate()
        XCTAssertFalse(keeper.isHolding)
        busy = true
        keeper.evaluate(); keeper.evaluate()
        XCTAssertTrue(keeper.isHolding)
        XCTAssertEqual(begun, 1, "one assertion, not one per poll")
        busy = false
        keeper.evaluate()
        XCTAssertFalse(keeper.isHolding)
        XCTAssertEqual(ended, 1)
        keeper.evaluate()
        XCTAssertEqual(ended, 1)
    }

    func testStopReleasesAHeldAssertion() {
        var ended = 0
        let keeper = PowerActivityKeeper(isBusy: { true }, begin: { _ in Token() }, end: { _ in ended += 1 })
        keeper.evaluate()
        keeper.stop()
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(keeper.isHolding)
    }

    func testReasonNamesTheOptionsUsed() {
        // The real assertion uses user-initiated activity that also blocks idle system sleep.
        XCTAssertFalse(PowerActivityKeeper.reason.isEmpty)
    }
}

final class HelperUpdateTests: XCTestCase {
    private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    private func defaults(pending version: String?) -> UserDefaults {
        let d = UserDefaults(suiteName: "HelperUpdateTests-\(UUID().uuidString)")!
        if let version { d.set(version, forKey: UpdatePrefs2.helperChangedKey) }
        return d
    }

    func testNothingPendingDoesNothing() {
        var calls = 0
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: defaults(pending: nil), currentVersion: "2.0",
            unregister: { calls += 1; return .notRegistered }, register: { calls += 1; return .enabled })
        XCTAssertEqual(r, .notNeeded)
        XCTAssertEqual(calls, 0)
    }

    func testMarkerWrittenFromAReleaseTagStillMatchesTheBundleVersion() {
        // Regression: the marker holds "v2.0" (the tag) and the bundle version is "2.0".
        let d = defaults(pending: "v2.0")
        var order: [String] = []
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: d, currentVersion: "2.0",
            unregister: { order.append("unregister"); return .notRegistered },
            register: { order.append("register"); return .enabled })
        XCTAssertEqual(r, .reRegistered)
        XCTAssertEqual(order, ["unregister", "register"])
    }

    func testPendingForAnotherVersionIsIgnored() {
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: defaults(pending: "1.0"), currentVersion: "2.0",
            unregister: { .notRegistered }, register: { .enabled })
        XCTAssertEqual(r, .notNeeded)
    }

    func testSuccessReRegistersAndClearsTheMarker() {
        let d = defaults(pending: "2.0")
        var order: [String] = []
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: d, currentVersion: "2.0",
            unregister: { order.append("unregister"); return .notRegistered },
            register: { order.append("register"); return .enabled })
        XCTAssertEqual(r, .reRegistered)
        XCTAssertEqual(order, ["unregister", "register"])
        XCTAssertNil(d.string(forKey: UpdatePrefs2.helperChangedKey))
    }

    func testFailedUnregisterStillTriesToRegister() {
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: defaults(pending: "2.0"), currentVersion: "2.0",
            unregister: { throw Boom() }, register: { .enabled })
        XCTAssertEqual(r, .reRegistered)
    }

    func testFailedRegisterIsReportedAndKeepsTheMarker() {
        let d = defaults(pending: "2.0")
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: d, currentVersion: "2.0",
            unregister: { .notRegistered }, register: { throw Boom() })
        XCTAssertEqual(r, .failed("boom"))
        XCTAssertEqual(d.string(forKey: UpdatePrefs2.helperChangedKey), "2.0", "retried on the next launch")
    }

    func testRequiresApprovalIsAFailureWithAGuide() {
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: defaults(pending: "2.0"), currentVersion: "2.0",
            unregister: { .notRegistered }, register: { .requiresApproval })
        guard case .failed(let message) = r else { return XCTFail("expected a failure, got \(r)") }
        XCTAssertTrue(message.contains("Login Items"))
    }

    func testNotFoundIsAFailure() {
        let r = UpdateInstaller.finishPendingHelperUpdate(
            defaults: defaults(pending: "2.0"), currentVersion: "2.0",
            unregister: { .notRegistered }, register: { .notFound })
        XCTAssertEqual(r, .failed(HelperRegistration.plainDescription(.notFound)))
    }
}
