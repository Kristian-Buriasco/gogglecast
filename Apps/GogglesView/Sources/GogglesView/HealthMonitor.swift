import Foundation
import CoreMedia

// ─────────────────────────────────────────────────────────────────────────
// Connection health: the collecting half. A fixed-size ring buffer per event
// kind, fed by a timestamped event stream (frame arrived, decode failure,
// drop, parameter set, decode latency). Nothing here reads a clock except
// through the injected `clock`, and `snapshot(now:)` is a pure function of
// what was recorded, so `HealthMonitorTests` can drive it with synthetic
// timings. Percentile maths are shared with the benchmark (`BenchmarkStats`).
//
// Cost model: the monitor only exists while the Connection health window is
// open (it is registered as a `DecodeSession` consumer then, and removed on
// close). Per frame it does one lock, one clock read and one O(1) ring
// append. Statistics are computed once a second by the window, not per frame.
// ─────────────────────────────────────────────────────────────────────────

/// Fixed-capacity ring: O(1) append, oldest element overwritten when full.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest first.
    var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage[storage.count - 1] : storage[(head + capacity - 1) % capacity]
    }
}

/// One second of the window, for the sparkline charts.
struct HealthBucket: Equatable {
    /// Seconds before the end of the window (0 = most recent second).
    var secondsAgo: Int
    var frames: Int
    var megabitsPerSecond: Double
    /// Longest inter-frame gap that ended in this second.
    var maxGapMs: Double
    var problems: Int
    var latencyMs: Double?
}

struct HealthSnapshot: Equatable {
    /// Seconds of data the figures cover (<= window length).
    var spanSeconds: Double
    var frames: Int
    /// Last ~2 s, so the headline reacts quickly.
    var fps: Double
    var bitrateMbps: Double
    var gapP50Ms: Double?
    var gapP95Ms: Double?
    var gapMaxMs: Double?
    /// Gaps over 100 / 250 / 500 ms.
    var stalls100: Int
    var stalls250: Int
    var stalls500: Int
    /// Counts per `HealthMonitor.histogramEdgesMs` bin.
    var histogram: [Int]
    var decodeFailures: Int
    var drops: Int
    var secondsSinceLastFrame: Double?
    var parameterSets: Int
    var parameterSetIntervalMs: Double?
    var latencyMs: Double?
    var latencyP95Ms: Double?
    /// Oldest first.
    var series: [HealthBucket]

    /// (failures + drops) as a percentage of frames expected (arrived + dropped).
    var lossPercent: Double {
        let expected = frames + drops
        return expected > 0 ? Double(decodeFailures + drops) / Double(expected) * 100 : 0
    }

    static let empty = HealthSnapshot(
        spanSeconds: 0, frames: 0, fps: 0, bitrateMbps: 0, gapP50Ms: nil, gapP95Ms: nil, gapMaxMs: nil,
        stalls100: 0, stalls250: 0, stalls500: 0, histogram: [Int](repeating: 0, count: HealthMonitor.histogramEdgesMs.count),
        decodeFailures: 0, drops: 0, secondsSinceLastFrame: nil, parameterSets: 0, parameterSetIntervalMs: nil,
        latencyMs: nil, latencyP95Ms: nil, series: []
    )
}

final class HealthMonitor: SampleBufferRendering {
    static let defaultWindowSeconds = 120
    /// Lower edge of each histogram bin in ms; the last bin is open-ended.
    static let histogramEdgesMs: [Double] = [0, 8, 12, 18, 25, 35, 50, 100]
    /// Seconds used for the headline fps / bitrate.
    static let headlineSeconds = 2.0

    private struct Frame { var ns: UInt64; var bytes: Int }
    private struct Counted { var ns: UInt64; var count: Int }
    private struct Latency { var ns: UInt64; var ms: Double }

    private let clock: () -> UInt64
    let windowSeconds: Int
    private let lock = NSLock()
    private var frames: RingBuffer<Frame>
    private var failures = RingBuffer<Counted>(capacity: 4096)
    private var drops = RingBuffer<Counted>(capacity: 4096)
    private var paramSets = RingBuffer<UInt64>(capacity: 1024)
    private var latencies = RingBuffer<Latency>(capacity: 4096)
    private var startedNs: UInt64
    private var lastHelperDrops: Int?

    init(windowSeconds: Int = HealthMonitor.defaultWindowSeconds,
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.windowSeconds = windowSeconds
        self.clock = clock
        self.frames = RingBuffer(capacity: max(1024, windowSeconds * 130))
        self.startedNs = clock()
    }

    // MARK: SampleBufferRendering (frames)

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        frameArrived(at: clock(), bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
    }

    func flush() {}

    // MARK: Event stream

    func start(at ns: UInt64) {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll(); failures.removeAll(); drops.removeAll(); paramSets.removeAll(); latencies.removeAll()
        startedNs = ns
        lastHelperDrops = nil
    }

    func frameArrived(at ns: UInt64, bytes: Int) {
        lock.lock(); frames.append(Frame(ns: ns, bytes: bytes)); lock.unlock()
    }

    func decodeFailure(at ns: UInt64) {
        lock.lock(); failures.append(Counted(ns: ns, count: 1)); lock.unlock()
    }

    func decodeFailure() { decodeFailure(at: clock()) }

    func drop(at ns: UInt64, count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); drops.append(Counted(ns: ns, count: count)); lock.unlock()
    }

    func parameterSet() { parameterSet(at: clock()) }

    func parameterSet(at ns: UInt64) {
        lock.lock(); paramSets.append(ns); lock.unlock()
    }

    func decodeLatency(ms: Double, at ns: UInt64) {
        lock.lock(); latencies.append(Latency(ns: ns, ms: ms)); lock.unlock()
    }

    /// Feed the helper's running drop total (`StreamStats.cumulativeDrops`);
    /// the increase since the previous call becomes drop events. A total that
    /// went backwards (helper restarted the stream) only re-baselines.
    func observeHelperDrops(cumulative: Int, at ns: UInt64) {
        lock.lock()
        let previous = lastHelperDrops
        lastHelperDrops = cumulative
        lock.unlock()
        if let previous, cumulative > previous { drop(at: ns, count: cumulative - previous) }
    }

    // MARK: Snapshot

    func snapshot() -> HealthSnapshot { snapshot(now: clock()) }

    func snapshot(now: UInt64) -> HealthSnapshot {
        lock.lock()
        let frameList = frames.elements, failureList = failures.elements, dropList = drops.elements
        let paramList = paramSets.elements, latencyList = latencies.elements, started = startedNs
        lock.unlock()
        return HealthMonitor.compute(
            now: now, startedNs: started, windowSeconds: windowSeconds,
            frames: frameList.map { ($0.ns, $0.bytes) },
            failures: failureList.map { ($0.ns, $0.count) }, drops: dropList.map { ($0.ns, $0.count) },
            paramSets: paramList, latencies: latencyList.map { ($0.ns, $0.ms) }
        )
    }

    /// Pure core of `snapshot`. Everything is nanoseconds on one clock.
    static func compute(now: UInt64, startedNs: UInt64, windowSeconds: Int,
                        frames: [(ns: UInt64, bytes: Int)], failures: [(ns: UInt64, count: Int)],
                        drops: [(ns: UInt64, count: Int)], paramSets: [UInt64],
                        latencies: [(ns: UInt64, ms: Double)]) -> HealthSnapshot {
        let windowNs = UInt64(windowSeconds) * 1_000_000_000
        let windowStart = max(startedNs, now > windowNs ? now - windowNs : 0)
        let elapsed = now > windowStart ? Double(now - windowStart) / 1e9 : 0
        func inWindow(_ ns: UInt64) -> Bool { ns >= windowStart && ns <= now }

        let f = frames.filter { inWindow($0.ns) }
        let fail = failures.filter { inWindow($0.ns) }
        let drp = drops.filter { inWindow($0.ns) }
        let params = paramSets.filter(inWindow)
        let lat = latencies.filter { inWindow($0.ns) }

        let gaps = BenchmarkStats.intervalsMs(f.map { $0.ns })
        let sortedGaps = gaps.sorted()
        let paramGaps = BenchmarkStats.intervalsMs(params)
        let sortedLat = lat.map { $0.ms }.sorted()

        // Headline rate over the last couple of seconds (shorter if we have less data).
        let headSpan = min(headlineSeconds, elapsed)
        let headStart = now - UInt64(headSpan * 1e9)
        let recent = f.filter { $0.ns >= headStart }
        let fps = headSpan > 0 ? Double(recent.count) / headSpan : 0
        let mbps = BenchmarkStats.megabitsPerSecond(bytes: recent.reduce(0) { $0 + $1.bytes }, durationSeconds: headSpan)

        var histogram = [Int](repeating: 0, count: histogramEdgesMs.count)
        for g in gaps {
            var bin = 0
            for (i, edge) in histogramEdgesMs.enumerated() where g >= edge { bin = i }
            histogram[bin] += 1
        }

        // Per-second buckets, oldest first.
        let nb = max(0, min(windowSeconds, Int(elapsed.rounded(.up))))
        var buckets = (0..<nb).map { HealthBucket(secondsAgo: nb - 1 - $0, frames: 0, megabitsPerSecond: 0, maxGapMs: 0, problems: 0, latencyMs: nil) }
        func index(_ ns: UInt64) -> Int? {
            let age = Int((now - ns) / 1_000_000_000)
            return age < nb ? nb - 1 - age : nil
        }
        var bucketBytes = [Int](repeating: 0, count: nb)
        var latSum = [Double](repeating: 0, count: nb), latN = [Int](repeating: 0, count: nb)
        for (i, frame) in f.enumerated() {
            guard let b = index(frame.ns) else { continue }
            buckets[b].frames += 1
            bucketBytes[b] += frame.bytes
            if i > 0 { buckets[b].maxGapMs = max(buckets[b].maxGapMs, Double(frame.ns &- f[i - 1].ns) / 1e6) }
        }
        for e in fail { if let b = index(e.ns) { buckets[b].problems += e.count } }
        for e in drp { if let b = index(e.ns) { buckets[b].problems += e.count } }
        for l in lat { if let b = index(l.ns) { latSum[b] += l.ms; latN[b] += 1 } }
        for b in buckets.indices {
            buckets[b].megabitsPerSecond = BenchmarkStats.megabitsPerSecond(bytes: bucketBytes[b], durationSeconds: 1)
            if latN[b] > 0 { buckets[b].latencyMs = latSum[b] / Double(latN[b]) }
        }

        // Time since the last frame is measured against everything recorded,
        // not just the window, so a long stall is reported honestly.
        let since = frames.last.map { now >= $0.ns ? Double(now - $0.ns) / 1e9 : 0 }

        func stalls(_ t: Double) -> Int { BenchmarkStats.stalls(intervalsMs: gaps, thresholdMs: t).count }
        return HealthSnapshot(
            spanSeconds: elapsed, frames: f.count, fps: fps, bitrateMbps: mbps,
            gapP50Ms: BenchmarkStats.percentile(sorted: sortedGaps, 50),
            gapP95Ms: BenchmarkStats.percentile(sorted: sortedGaps, 95),
            gapMaxMs: sortedGaps.last,
            stalls100: stalls(100), stalls250: stalls(250), stalls500: stalls(500),
            histogram: histogram,
            decodeFailures: fail.reduce(0) { $0 + $1.count }, drops: drp.reduce(0) { $0 + $1.count },
            secondsSinceLastFrame: since,
            parameterSets: params.count,
            parameterSetIntervalMs: paramGaps.isEmpty ? nil : BenchmarkStats.mean(paramGaps),
            latencyMs: sortedLat.isEmpty ? nil : BenchmarkStats.mean(sortedLat),
            latencyP95Ms: BenchmarkStats.percentile(sorted: sortedLat, 95),
            series: buckets
        )
    }
}
