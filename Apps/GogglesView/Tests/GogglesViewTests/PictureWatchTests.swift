import Foundation
import Testing
@testable import GogglesView

@Suite struct PictureChangeGateTests {
    private func s(_ sig: UInt64, luma: Double = 90) -> PictureWatch.Sample { .init(luma: luma, signature: sig) }

    /// Feeds the samples in order and returns the gate's answer for each.
    private func run(_ samples: [PictureWatch.Sample?]) -> [Bool] {
        var g = PictureChangeGate()
        return samples.map { g.observe($0) }
    }

    @Test func startsOnlyAfterSeveralChanges() {
        #expect(run([s(1), s(2), s(3), s(4)]) == [false, false, false, true], "three changes in a row")
    }

    @Test func aStaticPictureNeverStarts() {
        #expect(!run(Array(repeating: s(7), count: 50)).contains(true))
    }

    @Test func aRepeatedFrameRestartsTheCount() {
        #expect(run([s(1), s(2), s(3), s(3), s(4), s(5), s(6)]) == [false, false, false, false, false, false, true])
    }

    @Test func blackOrMissingPicturesNeverCountAndReset() {
        #expect(run([s(1), s(2), s(3, luma: 2), nil, s(4), s(5), s(6), s(7)]) == [false, false, false, false, false, false, false, true])
    }
}

@Suite struct AutoRecordPolicyTests {
    /// Drives the policy one reading per `step` seconds. A varying signature makes the picture 'change'.
    private struct Rig {
        var p = AutoRecordPolicy()
        var t = Date(timeIntervalSince1970: 1_000)
        var recording = false
        var n: UInt64 = 0
        mutating func tick(fps: Int?, seconds: Double = 0.25, changing: Bool = true, enabled: Bool = true) -> AutoRecordPolicy.Action {
            t = t.addingTimeInterval(seconds)
            n += 1
            let sample = PictureWatch.Sample(luma: 90, signature: changing ? n : 5)
            let a = p.observe(fps: fps, sample: sample, recording: recording, enabled: enabled, now: t)
            if a == .start { recording = true }
            if a == .stop { recording = false }
            return a
        }
        mutating func run(fps: Int?, for seconds: Double, changing: Bool = true) -> [AutoRecordPolicy.Action] {
            (0..<Int(seconds / 0.25)).map { _ in tick(fps: fps, changing: changing) }
        }
    }

    @Test func startsOnlyAfterTheRateHoldsAboveTenAndThePictureChanges() {
        var r = Rig()
        #expect(!r.run(fps: 8, for: 5).contains(.start), "8 fps is not enough")
        #expect(r.run(fps: 30, for: 3).contains(.start))
        var s = Rig()
        #expect(!s.run(fps: 30, for: 5, changing: false).contains(.start), "a static picture never starts")
    }

    @Test func stopsWhenTheRateSitsAtZeroAndStartsAgainWhenItReturns() {
        var r = Rig()
        _ = r.run(fps: 30, for: 3)
        #expect(r.recording)
        #expect(!r.run(fps: 0, for: 1).contains(.stop), "a one second gap is not a stop")
        _ = r.run(fps: 30, for: 1)
        #expect(r.recording, "the gap closed before 2 s, still recording")
        #expect(r.run(fps: 0, for: 3).contains(.stop))
        #expect(!r.recording)
        #expect(r.run(fps: 30, for: 3).contains(.start), "back above 10 fps: a new recording")
    }

    @Test func aManualStopIsNotUndoneUntilTheFeedWentAwayAndCameBack() {
        var r = Rig()
        _ = r.run(fps: 30, for: 3)
        r.recording = false                       // the user pressed Stop
        #expect(!r.run(fps: 30, for: 6).contains(.start), "still live: leave it stopped")
        _ = r.run(fps: 0, for: 3)                 // feed goes away
        #expect(r.run(fps: 30, for: 3).contains(.start), "feed returned")
    }

    @Test func itOnlyStopsRecordingsItStarted() {
        var r = Rig()
        r.recording = true                        // started by hand
        #expect(!r.run(fps: 0, for: 10).contains(.stop))
    }

    @Test func theGraceAfterAStartIsNotReadAsAManualStop() {
        var r = Rig()
        _ = r.run(fps: 30, for: 3)
        r.recording = false                       // recorder not reporting yet
        #expect(!r.run(fps: 30, for: 1).contains(.start))
        r.recording = true
        #expect(!r.run(fps: 30, for: 2).contains(.stop))
        #expect(!r.p.isSuppressed)
    }

    @Test func disabledDoesNothingAndForgetsState() {
        var r = Rig()
        for _ in 0..<40 { #expect(r.tick(fps: 30, enabled: false) == .none) }
    }
}
