import Testing
import Foundation
import GogglesXPC
@testable import GogglesView

struct BenchmarkStatsTests {
    private func close(_ a: Double?, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) < eps
    }

    @Test func percentileInterpolates() {
        let v: [Double] = [1, 2, 3, 4, 5]
        #expect(BenchmarkStats.percentile(sorted: v, 50) == 3)
        #expect(close(BenchmarkStats.percentile(sorted: v, 95), 4.8))
        #expect(BenchmarkStats.percentile(sorted: v, 0) == 1)
        #expect(BenchmarkStats.percentile(sorted: v, 100) == 5)
        #expect(BenchmarkStats.percentile(sorted: [7], 99) == 7)
        #expect(BenchmarkStats.percentile(sorted: [], 50) == nil)
    }

    @Test func standardDeviationIsPopulation() {
        #expect(close(BenchmarkStats.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9]), 2))
        #expect(BenchmarkStats.standardDeviation([5]) == 0)
        #expect(BenchmarkStats.standardDeviation([]) == 0)
    }

    @Test func distributionSortsInput() {
        let d = BenchmarkStats.distribution([5, 1, 4, 2, 3])!
        #expect(d.count == 5 && d.p50 == 3 && d.max == 5 && d.mean == 3)
        #expect(BenchmarkStats.distribution([]) == nil)
    }

    @Test func intervalsAndStalls() {
        #expect(BenchmarkStats.intervalsMs([0, 16_000_000, 33_000_000]) == [16, 17])
        #expect(BenchmarkStats.intervalsMs([5]) == [])
        let s = BenchmarkStats.stalls(intervalsMs: [10, 150, 101, 100])
        #expect(s.count == 2 && s.totalMs == 251)
    }

    @Test func onePercentLowUsesSlowestIntervals() {
        let intervals = [Double](repeating: 10, count: 198) + [50, 50]
        #expect(close(BenchmarkStats.onePercentLowFps(intervalsMs: intervals), 20))
        // Fewer than 100 intervals: the single worst one.
        #expect(close(BenchmarkStats.onePercentLowFps(intervalsMs: [10, 20, 40]), 25))
        #expect(BenchmarkStats.onePercentLowFps(intervalsMs: []) == nil)
    }

    /// 60 fps for 3 s plus a closing frame at exactly 3 s.
    private func steady60() -> [UInt64] {
        (0..<180).map { UInt64($0) * 16_666_667 } + [3_000_000_000]
    }

    @Test func minimumFpsCountsCompleteSeconds() {
        #expect(BenchmarkStats.minimumFps(arrivalsNs: steady60()) == 60)
        let gap = steady60().enumerated().filter { !(60..<90).contains($0.offset) }.map(\.element)
        #expect(BenchmarkStats.minimumFps(arrivalsNs: gap) == 30)
        #expect(BenchmarkStats.minimumFps(arrivalsNs: [0, 500_000_000]) == nil)
    }

    @Test func frameTimingSteadyStream() {
        let t = BenchmarkStats.frameTiming(arrivalsNs: steady60())
        #expect(t.frames == 181)
        #expect(close(t.fpsAverage, 60, 0.01))
        #expect(t.stalls == 0)
        #expect(t.jitterMs < 0.01)
        #expect(close(t.fpsOnePercentLow, 60, 0.1))
    }

    @Test func frameTimingWithStall() {
        let arrivals = steady60().enumerated().filter { !(60..<90).contains($0.offset) }.map(\.element)
        let t = BenchmarkStats.frameTiming(arrivalsNs: arrivals)
        #expect(t.frames == 151)
        #expect(close(t.fpsAverage, 50, 0.01))
        #expect(t.stalls == 1)
        #expect(close(t.stalledMs, 516.666677, 0.001))
        #expect(close(t.intervalMaxMs, 516.666677, 0.001))
        #expect(t.jitterMs > 30)
        #expect(t.fpsMinimum == 30)
    }

    @Test func emptyFrameTiming() {
        let t = BenchmarkStats.frameTiming(arrivalsNs: [])
        #expect(t.frames == 0 && t.fpsAverage == 0 && t.fpsMinimum == nil && t.fpsOnePercentLow == nil)
    }

    @Test func cpuAndBitrate() {
        #expect(BenchmarkStats.cpuPercent(cpuDeltaNs: 500_000_000, wallDeltaNs: 1_000_000_000) == 50)
        #expect(BenchmarkStats.cpuPercent(cpuDeltaNs: 5, wallDeltaNs: 0) == 0)
        #expect(BenchmarkStats.megabitsPerSecond(bytes: 1_250_000, durationSeconds: 2) == 5)
        #expect(BenchmarkStats.megabitsPerSecond(bytes: 1, durationSeconds: 0) == 0)
    }

    @Test func usbLinkSpeed() {
        #expect(USBLinkSpeed.describe(properties: ["USBSpeed": NSNumber(value: 3)]) == "High Speed (480 Mb/s)")
        #expect(USBLinkSpeed.describe(properties: ["UsbLinkSpeed": NSNumber(value: 5_000_000_000 as Int64)]) == "5 Gb/s")
        #expect(USBLinkSpeed.describe(properties: ["UsbLinkSpeed": NSNumber(value: 480_000_000)]) == "480 Mb/s")
        #expect(USBLinkSpeed.describe(properties: [:]) == nil)
        #expect(USBLinkSpeed.deviceSummary(vendor: 0x2ca3, product: 0x1f, bus: 1, address: 4, bcdDevice: 0x100)
                == "VID 0x2ca3 PID 0x001f, bus 1 address 4, bcdDevice 0x0100")
    }

    @Test func rendererDeltaRejectsBackwardsCounters() {
        let a = BenchmarkRendererCounters(totalFrames: 10, droppedFrames: 1, corruptedFrames: 0, optimizedCompositingFrames: 0)
        let b = BenchmarkRendererCounters(totalFrames: 70, droppedFrames: 3, corruptedFrames: 0, optimizedCompositingFrames: 5)
        #expect(BenchmarkRecorder.rendererDelta(start: a, end: b)
                == BenchmarkRendererCounters(totalFrames: 60, droppedFrames: 2, corruptedFrames: 0, optimizedCompositingFrames: 5))
        #expect(BenchmarkRecorder.rendererDelta(start: b, end: a) == nil)
        #expect(BenchmarkRecorder.rendererDelta(start: nil, end: b) == nil)
    }

    private let env = BenchmarkEnvironment(
        appVersion: "1.0 (1)", macOS: "Version 15.0", hardwareModel: "Mac15,3", cpuArch: "arm64",
        gogglesModel: "DJI Goggles 3", gogglesSerial: "…1234", usbLinkSpeed: "High Speed (480 Mb/s)",
        usbDevice: nil, resolution: "1920x1080"
    )

    private func stats(bytes: Int, drops: Int) -> StreamStats {
        StreamStats(fps: 60, bitrateKbps: 0, drops: 0, cumulativeFrames: 0, cumulativeBytes: bytes, cumulativeDrops: drops)
    }

    @Test func recorderBuildsResultFromSyntheticSamples() {
        let recorder = BenchmarkRecorder(clock: { 0 })
        recorder.record(arrivalNs: 1, hostTimeNs: 0, bytes: 99) // before start: ignored
        recorder.beginCollectingForTesting(startNs: 0, startStats: stats(bytes: 1_000, drops: 1))
        for i in 1...4 {
            let arrival = UInt64(i) * 400_000_000
            recorder.record(arrivalNs: arrival, hostTimeNs: arrival - UInt64(i) * 1_000_000, bytes: 125_000)
        }
        recorder.record(arrivalNs: 1_700_000_000, hostTimeNs: nil, bytes: 0)       // no stamp: no latency
        recorder.record(arrivalNs: 1_800_000_000, hostTimeNs: 2_000_000_000, bytes: 0) // stamp in the future: no latency
        let r = recorder.buildResult(endNs: 2_000_000_000, environment: env, endStats: stats(bytes: 501_000, drops: 4),
                                     decodeTeardowns: 1, renderer: nil)
        #expect(r.measuredSeconds == 2)
        #expect(r.frameTiming.frames == 6)
        #expect(r.latencyMs?.count == 4)
        #expect(close(r.latencyMs?.p50, 2.5))
        #expect(r.latencyMs?.max == 4)
        #expect(close(r.bitrateMbps, 2))        // 500_000 B * 8 / 2 s
        #expect(close(r.helperBitrateMbps, 2))
        #expect(r.helperDroppedFrames == 3)
        #expect(r.decodeTeardowns == 1)
        #expect(r.cpuAveragePercent == nil && r.memoryPeakMB == nil)
    }

    @Test func reportTextAndJSON() throws {
        let recorder = BenchmarkRecorder(clock: { 0 })
        recorder.beginCollectingForTesting(startNs: 0)
        recorder.record(arrivalNs: 10_000_000, hostTimeNs: 5_000_000, bytes: 10)
        recorder.record(arrivalNs: 26_000_000, hostTimeNs: 21_000_000, bytes: 10)
        var r = recorder.buildResult(endNs: 1_000_000_000, environment: env, endStats: nil, renderer: nil)
        r.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let text = BenchmarkReport.text(r)
        #expect(text.contains("p50 5.00 ms"))
        #expect(text.contains("USB link: High Speed (480 Mb/s)"))
        #expect(text.contains("goggles: DJI Goggles 3 serial …1234"))
        #expect(text.contains("decode-to-present: not measured"))
        #expect(text.contains("bitrate (helper): n/a"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(BenchmarkResult.self, from: BenchmarkReport.json(r))
        #expect(back == r)
    }
}
