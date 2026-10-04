import Foundation
import CoreMedia
import Combine
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Benchmark / latency mode: the collecting half. Registered on a
// `DecodeSession` as an extra `SampleBufferRendering` consumer for the
// duration of a run, so it sees exactly the sample buffers the display
// layer gets, right after the primary layer's `enqueue` returned. Each
// sample's PTS is the helper's `hostTime` (uptime ns, see
// `DecodeSession.makeSampleBuffer`), so "now - PTS" here is the same
// helper -> display-layer delay `DecodeSession.latencyMs` smooths for the OSD.
//
// Threading: `enqueue`/`flush` arrive on whatever queue drives the
// `DecodeSession` (main in practice) and only touch lock-guarded arrays;
// start/progress/finish run on main.
// ─────────────────────────────────────────────────────────────────────────

/// What a run needs from a goggles session. Built from a `GogglesSession` in
/// the app (`BenchmarkTarget(session:)`); tests can build one by hand.
struct BenchmarkTarget {
    let label: String
    let decodeSession: DecodeSession
    let isLive: () -> Bool
    let stats: () -> StreamStats?
    let environment: () -> BenchmarkEnvironment
}

/// Points the benchmark at the session app-level commands act on (key goggles
/// window, else the most recently focused one). Set once in main.swift.
enum BenchmarkRouting {
    static var targetProvider: (() -> BenchmarkTarget?)?
}

/// Process CPU time and memory footprint.
enum ProcessSampler {
    /// User + system CPU time of this process, all threads.
    static func cpuTimeNs() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func ns(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1_000 }
        return ns(usage.ru_utime) + ns(usage.ru_stime)
    }

    /// `phys_footprint` (what Activity Monitor calls "Memory").
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

final class BenchmarkRecorder: ObservableObject, SampleBufferRendering {
    enum Phase: Equatable { case idle, running, finished }

    static let durations: [Int] = [10, 30, 60, 120]
    static let defaultSeconds = 30

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var liveFrames = 0
    @Published private(set) var result: BenchmarkResult?

    private let clock: () -> UInt64
    private let lock = NSLock()
    private var collecting = false
    private var arrivals: [UInt64] = []
    private var latenciesMs: [Double] = []
    private var bytes = 0
    private var startTeardowns = 0

    private var target: BenchmarkTarget?
    private var requestedSeconds: Double = 0
    private var startedAt = Date()
    private var startNs: UInt64 = 0
    private var startStats: StreamStats?
    private var startRenderer: BenchmarkRendererCounters?
    private var lastCpuNs: UInt64 = 0
    private var lastWallNs: UInt64 = 0
    private var cpuSamples: [Double] = []
    private var memorySamples: [UInt64] = []
    private var timer: Timer?

    init(clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
    }

    deinit {
        timer?.invalidate()
        if let target { target.decodeSession.removeConsumer(self) }
    }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = (pts.isValid && pts.timescale == 1_000_000_000 && pts.value >= 0) ? UInt64(pts.value) : nil
        record(arrivalNs: clock(), hostTimeNs: hostTime, bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
    }

    /// `DecodeSession` only flushes its primary renderer (on teardown), never
    /// extra consumers; teardowns are counted via `teardownCount` instead.
    func flush() {}

    /// One enqueued sample. Internal so tests can feed synthetic timings.
    func record(arrivalNs: UInt64, hostTimeNs: UInt64?, bytes sampleBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        guard collecting else { return }
        arrivals.append(arrivalNs)
        if let hostTimeNs, arrivalNs >= hostTimeNs {
            latenciesMs.append(Double(arrivalNs - hostTimeNs) / 1_000_000)
        }
        bytes += sampleBytes
    }

    // MARK: Run control (main thread)

    func start(target: BenchmarkTarget, seconds: Int) {
        guard phase != .running else { return }
        self.target = target
        requestedSeconds = Double(seconds)
        result = nil
        progress = 0
        liveFrames = 0
        cpuSamples = []
        memorySamples = []
        startStats = target.stats()
        startTeardowns = target.decodeSession.teardownCount
        startRenderer = nil
        startedAt = Date()
        startNs = clock()
        lastWallNs = startNs
        lastCpuNs = ProcessSampler.cpuTimeNs()
        lock.lock()
        arrivals = []
        arrivals.reserveCapacity(seconds * 130)
        latenciesMs = []
        latenciesMs.reserveCapacity(seconds * 130)
        bytes = 0
        collecting = true
        lock.unlock()
        phase = .running
        target.decodeSession.loadRendererCounters { [weak self] in self?.startRenderer = $0 }
        target.decodeSession.addConsumer(self)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func cancel() {
        guard phase == .running else { return }
        stopCollecting()
        phase = .idle
        progress = 0
    }

    private func tick() {
        let now = clock()
        let cpu = ProcessSampler.cpuTimeNs()
        cpuSamples.append(BenchmarkStats.cpuPercent(cpuDeltaNs: cpu &- lastCpuNs, wallDeltaNs: now &- lastWallNs))
        lastCpuNs = cpu
        lastWallNs = now
        if let footprint = ProcessSampler.footprintBytes() { memorySamples.append(footprint) }
        let elapsed = Double(now &- startNs) / 1_000_000_000
        progress = min(1, elapsed / requestedSeconds)
        lock.lock(); liveFrames = arrivals.count; lock.unlock()
        if elapsed >= requestedSeconds { finish(endNs: now) }
    }

    private func stopCollecting() {
        timer?.invalidate()
        timer = nil
        lock.lock(); collecting = false; lock.unlock()
        target?.decodeSession.removeConsumer(self)
    }

    private func finish(endNs: UInt64) {
        stopCollecting()
        guard let target else { return }
        let endStats = target.stats()
        let environment = target.environment()
        let teardowns = max(0, target.decodeSession.teardownCount - startTeardowns)
        target.decodeSession.loadRendererCounters { [weak self] endRenderer in
            guard let self else { return }
            self.result = self.buildResult(
                endNs: endNs, environment: environment, endStats: endStats, decodeTeardowns: teardowns,
                renderer: BenchmarkRecorder.rendererDelta(start: self.startRenderer, end: endRenderer)
            )
            self.progress = 1
            self.phase = .finished
            self.target = nil
        }
    }

    /// Internal for tests: builds the result from what has been recorded so far.
    func buildResult(endNs: UInt64, environment: BenchmarkEnvironment, endStats: StreamStats?,
                     decodeTeardowns: Int = 0, renderer: BenchmarkRendererCounters?) -> BenchmarkResult {
        lock.lock()
        let arrivals = self.arrivals, latencies = latenciesMs, bytes = self.bytes
        lock.unlock()
        let measured = Double(endNs &- startNs) / 1_000_000_000
        var helperBitrate: Double?
        var helperDrops: Int?
        if let a = startStats, let b = endStats, b.cumulativeBytes >= a.cumulativeBytes {
            helperBitrate = BenchmarkStats.megabitsPerSecond(bytes: b.cumulativeBytes - a.cumulativeBytes, durationSeconds: measured)
            helperDrops = max(0, b.cumulativeDrops - a.cumulativeDrops)
        }
        let mb = 1024.0 * 1024.0
        return BenchmarkResult(
            startedAt: startedAt,
            requestedSeconds: requestedSeconds,
            measuredSeconds: measured,
            environment: environment,
            frameTiming: BenchmarkStats.frameTiming(arrivalsNs: arrivals),
            latencyMs: BenchmarkStats.distribution(latencies),
            bitrateMbps: BenchmarkStats.megabitsPerSecond(bytes: bytes, durationSeconds: measured),
            helperBitrateMbps: helperBitrate,
            helperDroppedFrames: helperDrops,
            decodeTeardowns: decodeTeardowns,
            renderer: renderer,
            cpuAveragePercent: cpuSamples.isEmpty ? nil : BenchmarkStats.mean(cpuSamples),
            cpuPeakPercent: cpuSamples.max(),
            memoryPeakMB: memorySamples.max().map { Double($0) / mb },
            memoryEndMB: memorySamples.last.map { Double($0) / mb }
        )
    }

    /// Counter deltas; nil if either end is missing or the counters went
    /// backwards (layer replaced mid-run), rather than reporting nonsense.
    static func rendererDelta(start: BenchmarkRendererCounters?, end: BenchmarkRendererCounters?) -> BenchmarkRendererCounters? {
        guard let start, let end else { return nil }
        let d = BenchmarkRendererCounters(
            totalFrames: end.totalFrames - start.totalFrames,
            droppedFrames: end.droppedFrames - start.droppedFrames,
            corruptedFrames: end.corruptedFrames - start.corruptedFrames,
            optimizedCompositingFrames: end.optimizedCompositingFrames - start.optimizedCompositingFrames
        )
        guard d.totalFrames >= 0, d.droppedFrames >= 0, d.corruptedFrames >= 0, d.optimizedCompositingFrames >= 0 else { return nil }
        return d
    }

    /// Test hook: begin collecting without a session/timer.
    func beginCollectingForTesting(startNs: UInt64, startStats: StreamStats? = nil) {
        self.startNs = startNs
        self.startStats = startStats
        lock.lock(); collecting = true; lock.unlock()
    }
}
