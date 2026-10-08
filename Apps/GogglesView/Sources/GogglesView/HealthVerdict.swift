import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Connection health: the plain-language verdict. Pure: a `HealthSnapshot`
// in, a level + reasons + suggestions out. All thresholds live in
// `HealthVerdict.Thresholds` so tests (and future tuning) touch one place.
//
// Gap thresholds are relative to the median gap, so a steady 30 fps stream is
// not penalised against a 60 fps expectation; the absolute floors stop tiny
// medians (120 fps) from making ordinary scheduling noise look unstable.
// ─────────────────────────────────────────────────────────────────────────

struct HealthVerdict: Equatable {
    enum Level: String, Equatable {
        case noData = "No data", healthy = "Healthy", unstable = "Unstable", poor = "Poor"

        /// Localized name for the window; the raw value stays English for reports.
        var title: String {
            switch self {
            case .noData: return L("No data")
            case .healthy: return L("Healthy")
            case .unstable: return L("Unstable")
            case .poor: return L("Poor")
            }
        }
    }

    struct Thresholds {
        /// Unstable when p95 gap exceeds max(p50 * factor, floor).
        var unstableGapFactor = 2.0
        var unstableGapFloorMs = 34.0
        var poorGapFactor = 4.0
        var poorGapFloorMs = 100.0
        /// Failures + drops as a percentage of expected frames.
        var unstableLossPercent = 1.0
        var poorLossPercent = 5.0
        /// Unstable at this many gaps over 250 ms, Poor at this many over 500 ms.
        var unstableStalls250 = 2
        var poorStalls500 = 3
        /// Poor when no frame has arrived for this long.
        var silentSeconds = 3.0
        /// Fewer frames than this in the window is too little to judge.
        var minimumFrames = 30
    }

    var level: Level
    var reasons: [String]
    var suggestions: [String]

    static var cableTip: String { L("Try another USB cable that carries data; many cables are charge-only, and long or thin ones struggle with USB 3.") }
    static var directPortTip: String { L("Plug into a port on the Mac directly rather than through a hub or dock.") }
    static var interferenceTip: String { L("Move other USB 3 devices, hubs and drives away from the goggles and its cable; USB 3 noise disturbs 2.4 GHz radio links.") }
    static var otgTip: String { L("Check the goggles' OTG / USB setting so the goggles act as a device, then reconnect.") }

    static func evaluate(_ s: HealthSnapshot, thresholds t: Thresholds = Thresholds()) -> HealthVerdict {
        let silent = (s.secondsSinceLastFrame ?? 0) >= t.silentSeconds
        if s.frames < t.minimumFrames && !silent {
            return HealthVerdict(level: .noData, reasons: [L("Not enough frames yet to judge the connection.")], suggestions: [])
        }

        var poor: [String] = [], unstable: [String] = []
        var gapProblem = false, lossProblem = false

        if silent, let since = s.secondsSinceLastFrame {
            poor.append(L("No video for %lld s.", Int(since)))
        }
        if s.lossPercent >= t.poorLossPercent {
            poor.append(L("%.1f%% of frames were lost or failed to decode.", s.lossPercent)); lossProblem = true
        } else if s.lossPercent >= t.unstableLossPercent {
            unstable.append(L("%.1f%% of frames were lost or failed to decode.", s.lossPercent)); lossProblem = true
        }
        if let p95 = s.gapP95Ms, let p50 = s.gapP50Ms {
            if p95 > max(p50 * t.poorGapFactor, t.poorGapFloorMs) {
                poor.append(L("Frames arrive very unevenly (95%% of gaps under %.0f ms).", p95)); gapProblem = true
            } else if p95 > max(p50 * t.unstableGapFactor, t.unstableGapFloorMs) {
                unstable.append(L("Frames arrive unevenly (95%% of gaps under %.0f ms).", p95)); gapProblem = true
            }
        }
        if s.stalls500 >= t.poorStalls500 {
            poor.append(L("%lld pauses of half a second or more.", s.stalls500)); gapProblem = true
        } else if s.stalls250 >= t.unstableStalls250 {
            unstable.append(L("%lld pauses of a quarter second or more.", s.stalls250)); gapProblem = true
        }

        if !poor.isEmpty {
            return HealthVerdict(level: .poor, reasons: poor + unstable, suggestions: suggestions(silent: silent, loss: lossProblem, gaps: gapProblem))
        }
        if !unstable.isEmpty {
            return HealthVerdict(level: .unstable, reasons: unstable, suggestions: suggestions(silent: false, loss: lossProblem, gaps: gapProblem))
        }
        return HealthVerdict(level: .healthy, reasons: [], suggestions: [])
    }

    /// One to three tips, most likely fix first.
    private static func suggestions(silent: Bool, loss: Bool, gaps: Bool) -> [String] {
        var tips: [String]
        if silent { tips = [otgTip, cableTip, directPortTip] }
        else if loss && !gaps { tips = [cableTip, directPortTip] }
        else if gaps && !loss { tips = [directPortTip, interferenceTip, cableTip] }
        else { tips = [cableTip, directPortTip, interferenceTip] }
        return Array(tips.prefix(3))
    }
}

/// Plain-text output for the Copy report button and the Diagnostics report.
enum HealthReport {
    private static func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "n/a" }

    /// One line, for the Diagnostics report.
    static func summaryLine(_ s: HealthSnapshot, _ v: HealthVerdict) -> String {
        guard v.level != .noData else { return "no data (open Goggles > Connection health while streaming to measure)" }
        return String(format: "%@; %.0f fps, %.1f Mbps, gap p95 %@, %d failed/dropped over the last %.0f s",
                      v.level.rawValue, s.fps, s.bitrateMbps, ms(s.gapP95Ms), s.decodeFailures + s.drops, s.spanSeconds)
    }

    static func text(label: String, snapshot s: HealthSnapshot, verdict v: HealthVerdict, helperFps: Int? = nil, helperBitrateKbps: Double? = nil, date: Date = Date()) -> String {
        var lines = ["GogglesView connection health", "Device: \(label)", "Taken: \(DiagnosticsReport.timestamp(date))",
                     String(format: "Window: last %.0f s", s.spanSeconds), "", "Verdict: \(v.level.rawValue)"]
        lines += v.reasons.map { "  - \($0)" }
        if !v.suggestions.isEmpty {
            lines.append("Suggestions:")
            lines += v.suggestions.map { "  - \($0)" }
        }
        lines += ["",
                  String(format: "Frames per second: %.1f", s.fps),
                  String(format: "Video bitrate: %.2f Mbps", s.bitrateMbps),
                  "Frame gap p50 / p95 / max: \(ms(s.gapP50Ms)) / \(ms(s.gapP95Ms)) / \(ms(s.gapMaxMs))",
                  "Gaps over 100 / 250 / 500 ms: \(s.stalls100) / \(s.stalls250) / \(s.stalls500)",
                  "Dropped frames (helper): \(s.drops)",
                  "Decode failures: \(s.decodeFailures)",
                  String(format: "Loss: %.2f%%", s.lossPercent),
                  "Decode latency avg / p95: \(ms(s.latencyMs)) / \(ms(s.latencyP95Ms))",
                  "Parameter sets: \(s.parameterSets)" + (s.parameterSetIntervalMs.map { String(format: " (every %.1f s)", $0 / 1000) } ?? ""),
                  "Time since last frame: " + (s.secondsSinceLastFrame.map { String(format: "%.1f s", $0) } ?? "n/a")]
        if let helperFps { lines.append("Helper reports: \(helperFps) fps" + (helperBitrateKbps.map { String(format: ", %.0f kbps", $0) } ?? "")) }
        lines.append("Gap histogram (ms):")
        for (i, count) in s.histogram.enumerated() {
            lines.append("  \(binLabel(i)): \(count)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func binLabel(_ i: Int) -> String {
        let e = HealthMonitor.histogramEdgesMs
        return i + 1 < e.count ? "\(Int(e[i]))-\(Int(e[i + 1]))" : "\(Int(e[i]))+"
    }
}

/// Latest summary line for `DiagnosticsReport`, published by the Connection
/// health window while it is open (the report is built off the main thread).
enum HealthDiagnostics {
    private static let lock = NSLock()
    private static var line: String?

    static var summaryLine: String {
        lock.lock(); defer { lock.unlock() }
        return line ?? "not measured (open Goggles > Connection health while streaming)"
    }

    static func publish(_ newLine: String?) {
        lock.lock(); line = newLine; lock.unlock()
    }
}
