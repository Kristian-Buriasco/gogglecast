import XCTest
@testable import GogglesView

final class SignalAlertTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    /// `stability` 0 keeps the older "restored on the first picture" behaviour for the basic tests.
    private func policy(threshold: TimeInterval = 3, repeatEvery: TimeInterval = 5, stability: TimeInterval = 0) -> SignalAlertPolicy {
        SignalAlertPolicy(config: .init(threshold: threshold, repeatInterval: repeatEvery, restoreStability: stability))
    }

    func testNoAlertBeforeFirstFrame() {
        var p = policy()
        XCTAssertNil(p.tick(now: at(0)))
        XCTAssertNil(p.tick(now: at(100)))
    }

    func testNoAlertBeforeThreshold() {
        var p = policy()
        XCTAssertNil(p.frameArrived(at: at(0)))
        XCTAssertNil(p.tick(now: at(1)))
        XCTAssertNil(p.tick(now: at(2.99)))
    }

    func testLostAtThresholdOnlyOnce() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        XCTAssertEqual(p.tick(now: at(3)), .lost)
        XCTAssertNil(p.tick(now: at(3.5)))
        XCTAssertTrue(p.isLost)
    }

    func testRestoredOnFrame() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(4))
        XCTAssertEqual(p.frameArrived(at: at(5)), .restored)
        XCTAssertFalse(p.isLost)
        XCTAssertNil(p.frameArrived(at: at(5.1)))
    }

    func testRepeatReminders() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        XCTAssertEqual(p.tick(now: at(3)), .lost)
        XCTAssertNil(p.tick(now: at(7.9)))
        XCTAssertEqual(p.tick(now: at(8)), .repeatReminder)
        XCTAssertNil(p.tick(now: at(12)))
        XCTAssertEqual(p.tick(now: at(13)), .repeatReminder)
    }

    func testNoRepeatsAfterRestore() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(3))
        _ = p.frameArrived(at: at(4))
        _ = p.frameArrived(at: at(7))
        XCTAssertNil(p.tick(now: at(8)))
    }

    func testJitterShorterThanThresholdIgnored() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        XCTAssertNil(p.tick(now: at(2)))
        XCTAssertNil(p.frameArrived(at: at(2.5)))
        XCTAssertNil(p.tick(now: at(5)))
        XCTAssertNil(p.frameArrived(at: at(5.5)))
        XCTAssertNil(p.tick(now: at(8.4)))
        XCTAssertFalse(p.isLost)
    }

    func testUserDisconnectSuppressesAlerts() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        p.userDisconnected()
        XCTAssertNil(p.tick(now: at(10)))
        XCTAssertNil(p.tick(now: at(100)))
    }

    func testUserDisconnectWhileLostStopsReminders() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(3))
        p.userDisconnected()
        XCTAssertNil(p.tick(now: at(20)))
        XCTAssertNil(p.frameArrived(at: at(21)), "no restored notice after a user disconnect")
    }

    func testAlertsAgainAfterReconnect() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        p.userDisconnected()
        _ = p.frameArrived(at: at(50))
        XCTAssertEqual(p.tick(now: at(53)), .lost)
    }

    func testAcknowledgeStopsRemindersButKeepsRestored() {
        var p = policy()
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(3))
        p.acknowledge()
        XCTAssertNil(p.tick(now: at(30)))
        XCTAssertEqual(p.frameArrived(at: at(31)), .restored)
        _ = p.tick(now: at(40))
        XCTAssertEqual(p.tick(now: at(60)), .repeatReminder, "acknowledge resets on the next loss")
    }

    func testConfigChangeAppliesToNextTick() {
        var p = policy(threshold: 10)
        _ = p.frameArrived(at: at(0))
        XCTAssertNil(p.tick(now: at(5)))
        p.config.threshold = 4
        XCTAssertEqual(p.tick(now: at(5)), .lost)
    }

    func testPrefsDefaultsAndClamp() {
        let d = UserDefaults(suiteName: "SignalAlertTests-\(UUID().uuidString)")!
        XCTAssertTrue(SignalAlertPrefs.enabled(d))
        XCTAssertEqual(SignalAlertPrefs.threshold(d), 3)
        XCTAssertTrue(SignalAlertPrefs.soundEnabled(d))
        XCTAssertEqual(SignalAlertPrefs.soundName(d), "Sosumi")
        d.set(99, forKey: SignalAlertPrefs.thresholdKey)
        XCTAssertEqual(SignalAlertPrefs.threshold(d), 15)
        d.set(0, forKey: SignalAlertPrefs.thresholdKey)
        XCTAssertEqual(SignalAlertPrefs.threshold(d), 1)
        d.set("Bogus", forKey: SignalAlertPrefs.soundNameKey)
        XCTAssertEqual(SignalAlertPrefs.soundName(d), "Sosumi")
        XCTAssertEqual(SignalAlertPrefs.policyConfig(d).repeatInterval, 5)
    }

    // MARK: restore stability

    func testDefaultConfigWaitsTwoSecondsBeforeRestored() {
        XCTAssertEqual(SignalAlertPolicy.Config().restoreStability, 2)
    }

    func testRestoredWaitsForStablePeriod() {
        var p = policy(stability: 2)
        _ = p.frameArrived(at: at(0))
        XCTAssertEqual(p.tick(now: at(3)), .lost)
        XCTAssertNil(p.frameArrived(at: at(5)))
        XCTAssertTrue(p.isLost)
        XCTAssertNil(p.tick(now: at(6.9)))
        XCTAssertEqual(p.tick(now: at(7)), .restored)
        XCTAssertFalse(p.isLost)
        XCTAssertNil(p.tick(now: at(7.5)))
        XCTAssertNil(p.tick(now: at(30)), "nothing more after the restore")
    }

    func testFlappingDoesNotAnnounceRestored() {
        var p = policy(stability: 2)
        _ = p.frameArrived(at: at(0))
        XCTAssertEqual(p.tick(now: at(3)), .lost)
        var outputs: [SignalAlertPolicy.Output?] = []
        // Back for 1.5 s, dropped again, back again for 1.9 s, dropped: never stable for 2 s.
        outputs.append(p.frameArrived(at: at(10)))
        outputs.append(p.tick(now: at(11.4)))
        p.signalDropped(lastPicture: at(11.5 - 2))
        outputs.append(p.frameArrived(at: at(12)))
        outputs.append(p.tick(now: at(13.9)))
        p.signalDropped(lastPicture: at(13.9 - 2))
        outputs.append(p.tick(now: at(14)))
        XCTAssertFalse(outputs.contains(.restored), "no restored notice while flapping")
        XCTAssertTrue(p.isLost)
    }

    func testDropAfterPendingRestoreKeepsRepeatReminders() {
        var p = policy(stability: 2)
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(3))
        _ = p.frameArrived(at: at(4))
        p.signalDropped(lastPicture: at(4.5))
        XCTAssertEqual(p.tick(now: at(8)), .repeatReminder, "reminders resume (5 s after the first alert)")
    }

    func testBackdatedDropStillAlertsAtThreshold() {
        // The controller reports the drop when the watchdog fires, 2 s after the last picture.
        var p = policy(threshold: 3, stability: 2)
        _ = p.frameArrived(at: at(0))          // state became live
        p.signalDropped(lastPicture: at(10 - 2)) // state left live at t=10
        XCTAssertNil(p.tick(now: at(10)))
        XCTAssertNil(p.tick(now: at(10.9)))
        XCTAssertEqual(p.tick(now: at(11)), .lost, "3 s after the last picture")
    }

    func testRestoredWithoutPriorLossStaysSilent() {
        var p = policy(stability: 2)
        XCTAssertNil(p.frameArrived(at: at(0)))
        XCTAssertNil(p.tick(now: at(1)))
        XCTAssertNil(p.tick(now: at(2.5)))
    }

    func testUserDisconnectCancelsPendingRestore() {
        var p = policy(stability: 2)
        _ = p.frameArrived(at: at(0))
        _ = p.tick(now: at(3))
        _ = p.frameArrived(at: at(4))
        p.userDisconnected()
        XCTAssertNil(p.tick(now: at(10)))
        XCTAssertFalse(p.hasPendingRestore)
    }
}
