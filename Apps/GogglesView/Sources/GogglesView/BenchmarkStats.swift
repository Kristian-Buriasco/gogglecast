import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Benchmark / latency mode: the pure half. Everything here is plain math and
// string formatting over arrays of numbers, so `BenchmarkStatsTests` can
// drive it with synthetic frame timings. `BenchmarkRecorder` collects the
// raw samples; `BenchmarkView` shows the result. See docs/latency.md for what
// each number does (and does not) measure.
// ─────────────────────────────────────────────────────────────────────────

/// Summary of a set of values (milliseconds unless noted).
struct BenchmarkDistribution: Codable, Equatable {
    var count: Int
    var mean: Double
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
}

/// Frame-arrival timing over a run.
struct BenchmarkFrameTiming: Codable, Equatable {
    /// Samples (slice NALs) handed to the display layer.
    var frames: Int
    /// Average over the span from first to last frame.
    var fpsAverage: Double
    /// Fewest frames in any complete one-second window (from the first frame).
    var fpsMinimum: Double?
    /// 1000 / mean of the slowest 1% of frame intervals (at least one interval).
    var fpsOnePercentLow: Double?
    /// Standard deviation of frame intervals.
    var jitterMs: Double
    var intervalMeanMs: Double
    var intervalMaxMs: Double
    /// Gaps longer than `BenchmarkStats.stallThresholdMs`.
    var stalls: Int
    /// Sum of the stall gaps.
    var stalledMs: Double
}

enum BenchmarkStats {
    static let stallThresholdMs = 100.0

    /// Linear-interpolated percentile (`p` in 0...100) of already-sorted values.
    static func percentile(sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = Swift.min(Swift.max(p, 0), 100) / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return variance.squareRoot()
    }

    static func distribution(_ values: [Double]) -> BenchmarkDistribution? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return BenchmarkDistribution(
            count: sorted.count,
            mean: mean(sorted),
            p50: percentile(sorted: sorted, 50)!,
            p95: percentile(sorted: sorted, 95)!,
            p99: percentile(sorted: sorted, 99)!,
            max: sorted.last!
        )
    }

    /// Successive differences, in milliseconds, of nanosecond timestamps.
    static func intervalsMs(_ arrivalsNs: [UInt64]) -> [Double] {
        guard arrivalsNs.count > 1 else { return [] }
        return zip(arrivalsNs.dropFirst(), arrivalsNs).map { new, old in
            new >= old ? Double(new - old) / 1_000_000 : 0
        }
    }

    static func stalls(intervalsMs: [Double], thresholdMs: Double = stallThresholdMs) -> (count: Int, totalMs: Double) {
        let gaps = intervalsMs.filter { $0 > thresholdMs }
        return (gaps.count, gaps.reduce(0, +))
    }

    /// 1000 / mean of the slowest 1% of intervals.
    static func onePercentLowFps(intervalsMs: [Double]) -> Double? {
        guard !intervalsMs.isEmpty else { return nil }
        let n = Swift.max(1, intervalsMs.count / 100)
        let worst = mean(Array(intervalsMs.sorted(by: >).prefix(n)))
        return worst > 0 ? 1000 / worst : nil
    }

    /// Fewest frames in any complete one-second bucket, counted from the first frame.
    static func minimumFps(arrivalsNs: [UInt64]) -> Double? {
        guard let first = arrivalsNs.first, let last = arrivalsNs.last else { return nil }
        let completeBuckets = Int((last - first) / 1_000_000_000)
        guard completeBuckets > 0 else { return nil }
        var counts = [Int](repeating: 0, count: completeBuckets)
        for t in arrivalsNs {
            let bucket = Int((t - first) / 1_000_000_000)
            if bucket < completeBuckets { counts[bucket] += 1 }
        }
        return counts.min().map(Double.init)
    }

    /// `arrivalsNs` must be ascending (they are: one serial enqueue path).
    static func frameTiming(arrivalsNs: [UInt64]) -> BenchmarkFrameTiming {
        let intervals = intervalsMs(arrivalsNs)
        let spanMs = intervals.reduce(0, +)
        let stall = stalls(intervalsMs: intervals)
        return BenchmarkFrameTiming(
            frames: arrivalsNs.count,
            fpsAverage: spanMs > 0 ? Double(intervals.count) / (spanMs / 1000) : 0,
            fpsMinimum: minimumFps(arrivalsNs: arrivalsNs),
            fpsOnePercentLow: onePercentLowFps(intervalsMs: intervals),
            jitterMs: standardDeviation(intervals),
            intervalMeanMs: mean(intervals),
            intervalMaxMs: intervals.max() ?? 0,
            stalls: stall.count,
            stalledMs: stall.totalMs
        )
    }

    /// Process CPU time over wall time, as a percentage of one core.
    static func cpuPercent(cpuDeltaNs: UInt64, wallDeltaNs: UInt64) -> Double {
        wallDeltaNs == 0 ? 0 : Double(cpuDeltaNs) / Double(wallDeltaNs) * 100
    }

    static func megabitsPerSecond(bytes: Int, durationSeconds: Double) -> Double {
        durationSeconds > 0 ? Double(bytes) * 8 / durationSeconds / 1_000_000 : 0
    }
}

/// `USBSpeed` registry values (IOUSBHostFamilyDefinitions.h `tIOUSBHostConnectionSpeed`).
enum USBLinkSpeed {
    static func label(forSpeed value: Int) -> String {
        switch value {
        case 1: return "Full Speed (12 Mb/s)"
        case 2: return "Low Speed (1.5 Mb/s)"
        case 3: return "High Speed (480 Mb/s)"
        case 4: return "SuperSpeed (5 Gb/s)"
        case 5: return "SuperSpeed+ (10 Gb/s)"
        case 6: return "SuperSpeed+ 2x2 (20 Gb/s)"
        default: return "unknown (\(value))"
        }
    }

    /// Link speed from one USB device's registry properties: `USBSpeed`
    /// (IOUSBHostDevice), else `UsbLinkSpeed` (bits/s). nil if neither is present.
    static func describe(properties: [String: Any]) -> String? {
        if let speed = (properties["USBSpeed"] as? NSNumber)?.intValue { return label(forSpeed: speed) }
        if let bps = (properties["UsbLinkSpeed"] as? NSNumber)?.int64Value, bps > 0 {
            return bps >= 1_000_000_000 ? "\(bps / 1_000_000_000) Gb/s" : "\(bps / 1_000_000) Mb/s"
        }
        return nil
    }

    /// "VID 0x2ca3 PID 0x001f, bus 1 address 4, bcdDevice 0x0100" (from the helper's `DeviceInfo`).
    static func deviceSummary(vendor: UInt16, product: UInt16, bus: UInt8, address: UInt8, bcdDevice: UInt16) -> String {
        String(format: "VID 0x%04x PID 0x%04x, bus %ld address %ld, bcdDevice 0x%04x",
               UInt32(vendor), UInt32(product), Int(bus), Int(address), UInt32(bcdDevice))
    }
}

// MARK: - Result + report

struct BenchmarkEnvironment: Codable, Equatable {
    var appVersion: String
    var macOS: String
    var hardwareModel: String
    var cpuArch: String
    var gogglesModel: String?
    /// Last four characters only (same redaction as diagnostics).
    var gogglesSerial: String?
    var usbLinkSpeed: String?
    var usbDevice: String?
    var resolution: String?
}

/// Counters from the primary display layer's `AVSampleBufferVideoRenderer`,
/// as deltas over the run (macOS 14.4+; nil when unavailable).
struct BenchmarkRendererCounters: Codable, Equatable {
    var totalFrames: Int
    var droppedFrames: Int
    var corruptedFrames: Int
    var optimizedCompositingFrames: Int
}

struct BenchmarkResult: Codable, Equatable {
    var startedAt: Date
    var requestedSeconds: Double
    var measuredSeconds: Double
    var environment: BenchmarkEnvironment
    var frameTiming: BenchmarkFrameTiming
    /// Helper stamp -> handed to the display layer, ms.
    var latencyMs: BenchmarkDistribution?
    /// Average over the run, from the sample sizes the app enqueued (slices only).
    var bitrateMbps: Double
    /// Helper-reported (`StreamStats`) over the run, nil if no stats arrived.
    var helperBitrateMbps: Double?
    var helperDroppedFrames: Int?
    /// `DecodeSession` teardowns (30 consecutive decode failures) during the run.
    var decodeTeardowns: Int
    var renderer: BenchmarkRendererCounters?
    /// This process, % of one core.
    var cpuAveragePercent: Double?
    var cpuPeakPercent: Double?
    var memoryPeakMB: Double?
    var memoryEndMB: Double?
}

enum BenchmarkReport {
    static func text(_ r: BenchmarkResult) -> String {
        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        func opt(_ v: Double?, _ digits: Int = 1, suffix: String = "") -> String { v.map { f($0, digits) + suffix } ?? "n/a" }
        let e = r.environment
        let t = r.frameTiming
        var lines: [String] = []
        lines.append("GogglesView benchmark")
        lines.append("started: \(iso(r.startedAt))  duration: \(f(r.measuredSeconds)) s (requested \(f(r.requestedSeconds, 0)) s)")
        lines.append("")
        lines.append("== Environment ==")
        lines.append("app: \(e.appVersion)")
        lines.append("macOS: \(e.macOS)")
        lines.append("hardware: \(e.hardwareModel) (\(e.cpuArch))")
        lines.append("goggles: \(e.gogglesModel ?? "unknown") serial \(e.gogglesSerial ?? "unknown")")
        lines.append("USB link: \(e.usbLinkSpeed ?? "unknown")")
        lines.append("USB device: \(e.usbDevice ?? "unknown")")
        lines.append("resolution: \(e.resolution ?? "unknown")")
        lines.append("")
        lines.append("== Frames (arrival at display layer) ==")
        lines.append("frames: \(t.frames)")
        lines.append("fps: avg \(f(t.fpsAverage)), min 1s \(opt(t.fpsMinimum, 0)), 1% low \(opt(t.fpsOnePercentLow))")
        lines.append("frame interval: mean \(f(t.intervalMeanMs, 2)) ms, jitter (stddev) \(f(t.jitterMs, 2)) ms, max \(f(t.intervalMaxMs)) ms")
        lines.append("stalls (>\(f(BenchmarkStats.stallThresholdMs, 0)) ms): \(t.stalls), total \(f(t.stalledMs, 0)) ms")
        lines.append("")
        lines.append("== Latency: helper stamp -> display layer enqueue ==")
        if let l = r.latencyMs {
            lines.append("p50 \(f(l.p50, 2)) ms, p95 \(f(l.p95, 2)) ms, p99 \(f(l.p99, 2)) ms, max \(f(l.max, 2)) ms (mean \(f(l.mean, 2)), n=\(l.count))")
        } else {
            lines.append("no samples")
        }
        lines.append("decode-to-present: not measured (the display layer exposes no per-frame presented time)")
        lines.append("not measured: goggles-internal (sensor/air link/encode), USB transfer before the helper stamp, decode, compositing and display scan-out")
        lines.append("")
        lines.append("== Stream ==")
        lines.append("bitrate (app, slices): \(f(r.bitrateMbps, 2)) Mbps")
        lines.append("bitrate (helper): \(opt(r.helperBitrateMbps, 2, suffix: " Mbps"))")
        lines.append("dropped frames (helper reassembly): \(r.helperDroppedFrames.map(String.init) ?? "n/a")")
        lines.append("decode teardowns (30 consecutive failures): \(r.decodeTeardowns)")
        if let c = r.renderer {
            lines.append("renderer: \(c.totalFrames) frames, \(c.droppedFrames) dropped, \(c.corruptedFrames) corrupted, \(c.optimizedCompositingFrames) via optimized compositing")
        } else {
            lines.append("renderer counters: n/a")
        }
        lines.append("")
        lines.append("== Process ==")
        lines.append("CPU (% of one core): avg \(opt(r.cpuAveragePercent, suffix: "%")), peak \(opt(r.cpuPeakPercent, suffix: "%"))")
        lines.append("memory footprint: peak \(opt(r.memoryPeakMB, suffix: " MB")), end \(opt(r.memoryEndMB, suffix: " MB"))")
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ r: BenchmarkResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(r)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
