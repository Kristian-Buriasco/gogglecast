import XCTest
import CoreVideo
@testable import GogglesView
import GogglesXPC

private let t0 = Date(timeIntervalSince1970: 5_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

final class KeyframeRecoveryPolicyTests: XCTestCase {
    func testNothingWhileNotWaiting() {
        var p = KeyframeRecoveryPolicy()
        XCTAssertEqual(p.update(waiting: false, now: at(0)), .none)
        XCTAssertEqual(p.update(waiting: false, now: at(100)), .none)
    }

    func testRequestsKeyframeImmediatelyThenRepeats() {
        var p = KeyframeRecoveryPolicy()
        XCTAssertEqual(p.update(waiting: true, now: at(0)), .requestKeyframe)
        XCTAssertEqual(p.update(waiting: true, now: at(1.0)), .none)
        XCTAssertEqual(p.update(waiting: true, now: at(1.5)), .requestKeyframe)
        XCTAssertEqual(p.update(waiting: true, now: at(2.0)), .none)
    }

    func testEscalatesToReconnectAfterThreeSeconds() {
        var p = KeyframeRecoveryPolicy()
        _ = p.update(waiting: true, now: at(0))
        XCTAssertNotEqual(p.update(waiting: true, now: at(2.9)), .reconnect)
        XCTAssertEqual(p.update(waiting: true, now: at(3.0)), .reconnect)
        XCTAssertEqual(p.update(waiting: true, now: at(3.1)), .none)
    }

    func testReconnectsBackOff() {
        var p = KeyframeRecoveryPolicy()
        _ = p.update(waiting: true, now: at(0))
        XCTAssertEqual(p.update(waiting: true, now: at(3)), .reconnect)
        // Next reconnect only after 6 s more, not 3.
        XCTAssertNotEqual(p.update(waiting: true, now: at(6.5)), .reconnect)
        XCTAssertEqual(p.update(waiting: true, now: at(9)), .reconnect)
        // Then 12 s.
        XCTAssertNotEqual(p.update(waiting: true, now: at(20)), .reconnect)
        XCTAssertEqual(p.update(waiting: true, now: at(21)), .reconnect)
    }

    func testGettingAKeyframeResetsEverything() {
        var p = KeyframeRecoveryPolicy()
        _ = p.update(waiting: true, now: at(0))
        _ = p.update(waiting: true, now: at(3))
        XCTAssertEqual(p.update(waiting: false, now: at(4)), .none)
        XCTAssertNil(p.waitingSince)
        XCTAssertEqual(p.update(waiting: true, now: at(10)), .requestKeyframe)
        XCTAssertEqual(p.update(waiting: true, now: at(13)), .reconnect, "back to the first 3 s interval")
    }
}

final class StreamEventDebouncerTests: XCTestCase {
    func testLiveAnnouncedOnlyAfterStablePeriod() {
        var d = StreamEventDebouncer(stableFor: 3)
        d.observe(.live, at: at(0))
        XCTAssertNil(d.tick(at: at(2.9)))
        XCTAssertEqual(d.tick(at: at(3)), .streamLive)
        XCTAssertNil(d.tick(at: at(10)))
    }

    func testFlappingProducesNoEvents() {
        var d = StreamEventDebouncer(stableFor: 3)
        d.observe(.live, at: at(0))
        XCTAssertEqual(d.tick(at: at(3)), .streamLive)
        // live/stalled/live/stalled every 2 s
        d.observe(.stalled, at: at(10)); XCTAssertNil(d.tick(at: at(11.9)))
        d.observe(.live, at: at(12)); XCTAssertNil(d.tick(at: at(13)))
        d.observe(.stalled, at: at(14)); XCTAssertNil(d.tick(at: at(15.9)))
        d.observe(.live, at: at(16)); XCTAssertNil(d.tick(at: at(30)))
    }

    func testLostAnnouncedAfterStableLoss() {
        var d = StreamEventDebouncer(stableFor: 3)
        d.observe(.live, at: at(0)); _ = d.tick(at: at(3))
        d.observe(.stalled, at: at(10))
        d.observe(.handshaking, at: at(12)) // still not live: the window keeps running
        XCTAssertEqual(d.tick(at: at(13)), .streamLost)
        XCTAssertNil(d.tick(at: at(20)))
    }

    func testNeverLiveNeverLost() {
        var d = StreamEventDebouncer(stableFor: 3)
        d.observe(.claiming, at: at(0))
        d.observe(.handshaking, at: at(1))
        XCTAssertNil(d.tick(at: at(10)))
    }
}

final class NALBackpressureTests: XCTestCase {
    func testDeliversUnderLimit() {
        var g = NALBackpressure(limit: 1000)
        XCTAssertEqual(g.admit(bytes: 400, startsKeyframe: false), .deliver)
        XCTAssertEqual(g.admit(bytes: 400, startsKeyframe: false), .deliver)
        XCTAssertEqual(g.pendingBytes, 800)
        g.delivered(bytes: 400)
        XCTAssertEqual(g.pendingBytes, 400)
    }

    func testDropsAboveLimitUntilKeyframeOnDrainedQueue() {
        var g = NALBackpressure(limit: 1000)
        _ = g.admit(bytes: 900, startsKeyframe: false)
        XCTAssertEqual(g.admit(bytes: 200, startsKeyframe: false), .drop(firstOfRun: true))
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: false), .drop(firstOfRun: false))
        // A keyframe while the queue is still full stays dropped.
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: true), .drop(firstOfRun: false))
        g.delivered(bytes: 900)
        // Drained, but a plain slice still does not resume.
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: false), .drop(firstOfRun: false))
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: true), .resume)
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: false), .deliver)
        XCTAssertEqual(g.droppedCount, 4)
    }

    func testPendingNeverGoesNegative() {
        var g = NALBackpressure(limit: 100)
        g.delivered(bytes: 50)
        XCTAssertEqual(g.pendingBytes, 0)
    }

    func testSecondRunReportsFirstOfRunAgain() {
        var g = NALBackpressure(limit: 100)
        _ = g.admit(bytes: 90, startsKeyframe: false)
        XCTAssertEqual(g.admit(bytes: 50, startsKeyframe: false), .drop(firstOfRun: true))
        g.delivered(bytes: 90)
        XCTAssertEqual(g.admit(bytes: 10, startsKeyframe: true), .resume)
        _ = g.admit(bytes: 85, startsKeyframe: false)
        XCTAssertEqual(g.admit(bytes: 50, startsKeyframe: false), .drop(firstOfRun: true))
    }
}

final class HelperClientBacklogTests: XCTestCase {
    func testStalledMainQueueDropsAndNotifiesOnce() {
        let client = HelperClient(machServiceName: "test.never.connects")
        client.nalBacklogLimit = 1000
        var delivered = 0
        var dropNotices = 0
        var queued: [() -> Void] = []
        client.setHandlers(HelperDeviceHandlers(
            onNALUnit: { _, _, _, _ in delivered += 1 },
            onInputDropped: { dropNotices += 1 }), for: "dev")
        // A stalled main queue: delivery closures pile up instead of running.
        client.deliverOnMain = { queued.append($0) }
        let slice = Data(count: 400)
        for _ in 0..<6 { client.handleNALUnit("dev", slice, nalType: 1, isParameterSet: false, hostTime: 0) }
        // Two fit (800), the rest dropped; one drop notice queued.
        XCTAssertEqual(queued.count, 3)
        queued.forEach { $0() }
        queued.removeAll()
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(dropNotices, 1)
        // Queue drained: a keyframe resumes, plain slices are still dropped before it.
        client.handleNALUnit("dev", slice, nalType: 1, isParameterSet: false, hostTime: 0)
        XCTAssertTrue(queued.isEmpty)
        client.handleNALUnit("dev", slice, nalType: 5, isParameterSet: false, hostTime: 0)
        queued.forEach { $0() }
        XCTAssertEqual(delivered, 3)
    }
}

final class FrameClockWatchTests: XCTestCase {
    func testSteadyFramesDoNotJump() {
        var w = FrameClockWatch()
        var jumps = 0
        for i in 0..<30 where w.note(Int64(i) * 16_666_667) { jumps += 1 }
        XCTAssertEqual(jumps, 0)
        XCTAssertEqual(w.intervalMs ?? 0, 16.67, accuracy: 0.1)
    }

    func testBackwardsAndLargeGapsJump() {
        var w = FrameClockWatch()
        XCTAssertFalse(w.note(1_000_000_000))
        XCTAssertFalse(w.note(1_016_000_000))
        XCTAssertTrue(w.note(500_000_000), "clock went backwards")
        XCTAssertFalse(w.note(516_000_000))
        XCTAssertTrue(w.note(2_000_000_000), "stalled for more than a second")
        XCTAssertTrue(w.note(2_000_000_000), "duplicate timestamp")
    }
}

final class StabilizerBudgetTests: XCTestCase {
    func testWithinBudgetNeverBypasses() {
        var b = StabilizerBudget()
        for i in 0..<100 { b.record(costMs: 8, intervalMs: nil, atMs: Double(i) * 16) }
        XCTAssertFalse(b.isBypassed(atMs: 2000))
    }

    func testOverBudgetBypassesThenRetriesWithBackoff() {
        var b = StabilizerBudget()
        for i in 0..<5 { b.record(costMs: 20, intervalMs: nil, atMs: Double(i) * 16) } // trips at 64 ms
        XCTAssertTrue(b.isBypassed(atMs: 200))
        XCTAssertTrue(b.isBypassed(atMs: 2_000))
        XCTAssertFalse(b.isBypassed(atMs: 2_100), "first pause is 2 s")
        // Still too slow on the trial: the next pause is 4 s.
        for i in 0..<5 { b.record(costMs: 20, intervalMs: nil, atMs: 2_200 + Double(i) * 16) } // trips at 2264
        XCTAssertTrue(b.isBypassed(atMs: 6_200))
        XCTAssertFalse(b.isBypassed(atMs: 6_300))
    }

    func testBudgetUsesRealFrameInterval() {
        var slow = StabilizerBudget()
        for i in 0..<10 { slow.record(costMs: 20, intervalMs: 33.3, atMs: Double(i) * 33) }
        XCTAssertFalse(slow.isBypassed(atMs: 400), "20 ms is under 80% of a 30 fps interval")
        var fast = StabilizerBudget()
        for i in 0..<10 { fast.record(costMs: 20, intervalMs: 8.3, atMs: Double(i) * 8) }
        XCTAssertTrue(fast.isBypassed(atMs: 200))
    }

    func testIgnoresShortSpikes() {
        var b = StabilizerBudget()
        b.record(costMs: 50, intervalMs: nil, atMs: 0)
        b.record(costMs: 50, intervalMs: nil, atMs: 16)
        XCTAssertFalse(b.isBypassed(atMs: 20), "needs a few samples before judging")
    }
}

final class StabilizerResetTests: XCTestCase {
    private func buffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        return b!
    }

    func testResetAndCostAreSafeAcrossThreads() {
        let st = Stabilizer()
        let input = buffer(320, 180)
        let done = expectation(description: "reader")
        DispatchQueue.global().async {
            for _ in 0..<200 { _ = st.costMs; _ = st.isBypassed }
            done.fulfill()
        }
        for i in 0..<20 {
            if i % 5 == 0 { st.reset() }
            st.noteTimestamp(Int64(i) * 16_000_000)
            _ = st.process(input, strength: 0.5)
        }
        wait(for: [done], timeout: 10)
        XCTAssertNotNil(st.costMs)
    }

    func testTimestampJumpAndResetDoNotBreakProcessing() {
        let st = Stabilizer()
        let input = buffer(320, 180)
        _ = st.process(input, strength: 0.5)
        st.noteTimestamp(5_000_000_000)
        st.noteTimestamp(1_000)   // backwards: request a reset
        let out = st.process(input, strength: 0.5)
        XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
    }
}

final class OutputFrameStageTests: XCTestCase {
    private func buffer() -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &b)
        return b!
    }

    func testResultArrivesOnALaterPollAndOnlyOnce() {
        let stage = OutputFrameStage(label: "test.stage")
        let frame = buffer()
        let processed = buffer()
        XCTAssertNil(stage.next(source: { frame }, process: { _ in processed }))
        var got: CVPixelBuffer?
        let deadline = Date().addingTimeInterval(5)
        while got == nil, Date() < deadline {
            got = stage.next(source: { nil }, process: { _ in nil })
            if got == nil { usleep(2_000) }
        }
        XCTAssertTrue(got === processed)
        XCTAssertNil(stage.next(source: { nil }, process: { _ in nil }), "delivered once")
    }

    func testSlowJobsDoNotPileUp() {
        let stage = OutputFrameStage(label: "test.stage.slow")
        let frame = buffer()
        let started = NSLock()
        var jobs = 0
        for _ in 0..<50 {
            _ = stage.next(source: { frame }, process: { _ in
                started.lock(); jobs += 1; started.unlock()
                usleep(50_000)
                return nil
            })
        }
        started.lock(); let n = jobs; started.unlock()
        XCTAssertLessThanOrEqual(n, 2, "at most one job runs at a time")
    }

    func testResetDropsAFinishedPicture() {
        let stage = OutputFrameStage(label: "test.stage.reset")
        let frame = buffer()
        _ = stage.next(source: { frame }, process: { _ in frame })
        usleep(100_000)
        stage.reset()
        XCTAssertNil(stage.next(source: { nil }, process: { _ in nil }))
    }
}
