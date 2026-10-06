import Testing
import Foundation
@testable import GogglesView

struct HealthMonitorTests {
    private let sec: UInt64 = 1_000_000_000
    private let base: UInt64 = 5_000_000_000

    private func close(_ a: Double?, _ b: Double, _ eps: Double = 0.05) -> Bool {
        guard let a else { return false }
        return abs(a - b) < eps
    }

    /// Feeds `gapsMs` (cycled) until `seconds` have passed; returns the end time.
    @discardableResult
    private func feed(_ m: HealthMonitor, from start: UInt64, seconds: Double, gapsMs: [Double], bytes: Int = 12_500) -> UInt64 {
        var t = start
        let end = start + UInt64(seconds * 1e9)
        var i = 0
        while t < end {
            m.frameArrived(at: t, bytes: bytes)
            t += UInt64(gapsMs[i % gapsMs.count] * 1e6)
            i += 1
        }
        return end
    }

    private func monitor() -> HealthMonitor {
        let m = HealthMonitor(windowSeconds: 120, clock: { 0 })
        m.start(at: base)
        return m
    }

    // MARK: Ring buffer

    @Test func ringKeepsNewestInOrder() {
        var r = RingBuffer<Int>(capacity: 3)
        #expect(r.isEmpty && r.last == nil)
        for i in 1...2 { r.append(i) }
        #expect(r.elements == [1, 2] && r.last == 2)
        for i in 3...5 { r.append(i) }
        #expect(r.elements == [3, 4, 5])
        #expect(r.count == 3 && r.last == 5)
        r.append(6)
        #expect(r.elements == [4, 5, 6])
        r.removeAll()
        #expect(r.isEmpty && r.elements.isEmpty)
        r.append(9)
        #expect(r.elements == [9])
    }

    // MARK: Snapshot maths

    @Test func steady60fps() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 10, gapsMs: [1000.0 / 60])
        let s = m.snapshot(now: end)
        #expect(close(s.fps, 60, 1))
        #expect(close(s.gapP50Ms, 16.67) && close(s.gapP95Ms, 16.67) && close(s.gapMaxMs, 16.67))
        #expect(s.stalls100 == 0)
        #expect(s.histogram[2] == s.frames - 1)  // 12-18 ms bin
        #expect(HealthVerdict.evaluate(s).level == .healthy)
        #expect(s.series.count == 10)
        #expect(s.series.allSatisfy { abs($0.frames - 60) <= 1 })
    }

    @Test func bitrateFromBytes() {
        let m = monitor()
        // 60 fps * 12_500 B = 750 kB/s = 6 Mbps
        let end = feed(m, from: base, seconds: 10, gapsMs: [1000.0 / 60], bytes: 12_500)
        let s = m.snapshot(now: end)
        #expect(close(s.bitrateMbps, 6, 0.2))
        #expect(close(s.series[3].megabitsPerSecond, 6, 0.2))
    }

    @Test func windowDiscardsOldFrames() {
        let m = HealthMonitor(windowSeconds: 10, clock: { 0 })
        m.start(at: base)
        let end = feed(m, from: base, seconds: 30, gapsMs: [100])
        let s = m.snapshot(now: end)
        #expect(s.frames <= 101 && s.frames >= 99)
        #expect(close(s.spanSeconds, 10, 0.001))
        #expect(s.series.count == 10)
    }

    @Test func gapHistogramBins() {
        let m = monitor()
        var t = base
        for gap in [5.0, 10, 15, 20, 30, 40, 80, 150, 150] {
            m.frameArrived(at: t, bytes: 1)
            t += UInt64(gap * 1e6)
        }
        m.frameArrived(at: t, bytes: 1)
        let s = m.snapshot(now: t)
        #expect(s.histogram == [1, 1, 1, 1, 1, 1, 1, 2])
        #expect(s.stalls100 == 2)
    }

    @Test func parameterSetCadenceAndLatency() {
        let m = monitor()
        for i in 0..<5 { m.parameterSet(at: base + UInt64(i) * sec) }
        for i in 0..<10 { m.decodeLatency(ms: Double(10 + i), at: base + UInt64(i) * sec / 2) }
        let s = m.snapshot(now: base + 6 * sec)
        #expect(s.parameterSets == 5)
        #expect(close(s.parameterSetIntervalMs, 1000, 0.001))
        #expect(close(s.latencyMs, 14.5, 0.001))
        #expect(s.series.contains { $0.latencyMs != nil })
    }

    @Test func helperDropsBecomeDeltas() {
        let m = monitor()
        m.observeHelperDrops(cumulative: 10, at: base)            // baseline only
        m.observeHelperDrops(cumulative: 13, at: base + sec)
        m.observeHelperDrops(cumulative: 2, at: base + 2 * sec)   // helper restarted
        m.observeHelperDrops(cumulative: 4, at: base + 3 * sec)
        let s = m.snapshot(now: base + 4 * sec)
        #expect(s.drops == 5)
        #expect(s.series.map(\.problems).reduce(0, +) == 5)
    }

    @Test func timeSinceLastFrame() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 2, gapsMs: [100])
        #expect(close(m.snapshot(now: end + 3 * sec).secondsSinceLastFrame, 3.1, 0.15))
        #expect(HealthMonitor(windowSeconds: 10, clock: { 0 }).snapshot(now: 1).secondsSinceLastFrame == nil)
    }

    // MARK: Verdict

    @Test func tooFewFramesIsNoData() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 0.2, gapsMs: [16.7])
        let v = HealthVerdict.evaluate(m.snapshot(now: end))
        #expect(v.level == .noData && v.suggestions.isEmpty)
    }

    @Test func steady30fpsIsHealthy() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 20, gapsMs: [33.3])
        #expect(HealthVerdict.evaluate(m.snapshot(now: end)).level == .healthy)
    }

    @Test func healthyShowsNoSuggestions() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 10, gapsMs: [16.7, 16.7, 17, 16.4])
        let v = HealthVerdict.evaluate(m.snapshot(now: end))
        #expect(v.level == .healthy && v.suggestions.isEmpty && v.reasons.isEmpty)
    }

    @Test func burstyDeliveryIsUnstable() {
        let m = monitor()
        // Three frames 1 ms apart, then a 48 ms wait: still ~60 fps on average.
        let end = feed(m, from: base, seconds: 20, gapsMs: [1, 1, 48])
        let s = m.snapshot(now: end)
        #expect(close(s.fps, 60, 3))
        let v = HealthVerdict.evaluate(s)
        #expect(v.level == .unstable)
        #expect((1...3).contains(v.suggestions.count))
    }

    @Test func singleBlipDoesNotChangeVerdict() {
        let m = monitor()
        var t = feed(m, from: base, seconds: 10, gapsMs: [16.7])
        t += 300_000_000
        let end = feed(m, from: t, seconds: 10, gapsMs: [16.7])
        let s = m.snapshot(now: end)
        #expect(s.stalls250 == 1)
        #expect(HealthVerdict.evaluate(s).level == .healthy)
    }

    @Test func repeatedStallsEscalate() {
        func run(stalls: Int, gapMs: Double) -> HealthVerdict.Level {
            let m = monitor()
            var t = base
            for _ in 0..<stalls {
                t = feed(m, from: t, seconds: 5, gapsMs: [16.7]) + UInt64(gapMs * 1e6)
            }
            let end = feed(m, from: t, seconds: 5, gapsMs: [16.7])
            return HealthVerdict.evaluate(m.snapshot(now: end)).level
        }
        #expect(run(stalls: 2, gapMs: 300) == .unstable)
        #expect(run(stalls: 3, gapMs: 700) == .poor)
    }

    @Test func dropsAndFailuresRaiseLossVerdict() {
        func run(lossEvery: Int, failures: Bool) -> HealthVerdict {
            let m = monitor()
            let end = feed(m, from: base, seconds: 10, gapsMs: [16.7])
            let frames = m.snapshot(now: end).frames
            for i in 0..<(frames / lossEvery) {
                let at = base + UInt64(i) * sec / 10
                if failures { m.decodeFailure(at: at) } else { m.drop(at: at) }
            }
            return HealthVerdict.evaluate(m.snapshot(now: end))
        }
        #expect(run(lossEvery: 1000, failures: false).level == .healthy)
        let unstable = run(lossEvery: 50, failures: false)  // ~2%
        #expect(unstable.level == .unstable)
        #expect(unstable.suggestions.first == HealthVerdict.cableTip)
        #expect(run(lossEvery: 50, failures: true).level == .unstable)
        #expect(run(lossEvery: 10, failures: true).level == .poor)
    }

    @Test func silenceIsPoorAndSuggestsOTG() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 5, gapsMs: [16.7])
        let v = HealthVerdict.evaluate(m.snapshot(now: end + 6 * sec))
        #expect(v.level == .poor)
        #expect(v.suggestions.first == HealthVerdict.otgTip)
        #expect(v.suggestions.count <= 3)
    }

    @Test func thresholdsAreInjectable() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 10, gapsMs: [1, 1, 48])
        var strict = HealthVerdict.Thresholds()
        strict.unstableGapFloorMs = 100
        strict.unstableGapFactor = 100
        #expect(HealthVerdict.evaluate(m.snapshot(now: end), thresholds: strict).level == .healthy)
    }

    @Test func reportAndSummaryLine() {
        let m = monitor()
        let end = feed(m, from: base, seconds: 10, gapsMs: [16.7])
        let s = m.snapshot(now: end)
        let v = HealthVerdict.evaluate(s)
        let text = HealthReport.text(label: "Test goggles", snapshot: s, verdict: v)
        #expect(text.contains("Verdict: Healthy") && text.contains("Frame gap p50 / p95 / max"))
        #expect(HealthReport.summaryLine(s, v).hasPrefix("Healthy;"))
        #expect(HealthReport.summaryLine(.empty, HealthVerdict.evaluate(.empty)).hasPrefix("no data"))
    }
}
