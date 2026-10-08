#if canImport(AppKit)
import AppKit
import SwiftUI
import Charts
import Combine
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Connection health: the view. `ConnectionHealthModel` owns a `HealthMonitor`
// for as long as the window is open, registers it on the target session's
// `DecodeSession`, and once a second pulls a snapshot (plus the helper's
// stats and the smoothed decode latency) for the charts. Closing the window
// calls `stop()`, which unregisters everything, so nothing is collected while
// nobody is looking.
// ─────────────────────────────────────────────────────────────────────────

final class ConnectionHealthModel: ObservableObject {
    @Published private(set) var snapshot = HealthSnapshot.empty
    @Published private(set) var verdict = HealthVerdict.evaluate(.empty)
    @Published private(set) var helperStats: StreamStats?
    @Published private(set) var live = false

    let target: BenchmarkTarget
    private let monitor = HealthMonitor()
    private var timer: Timer?

    init(target: BenchmarkTarget) {
        self.target = target
    }

    deinit { stop() }

    var label: String { target.label }

    func start() {
        guard timer == nil else { return }
        monitor.start(at: DispatchTime.now().uptimeNanoseconds)
        target.decodeSession.addConsumer(monitor)
        target.decodeSession.healthMonitor = monitor
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        target.decodeSession.removeConsumer(monitor)
        if target.decodeSession.healthMonitor === monitor { target.decodeSession.healthMonitor = nil }
        HealthDiagnostics.publish(nil)
    }

    private func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let latency = target.decodeSession.decodeLatencyMs { monitor.decodeLatency(ms: latency, at: now) }
        let stats = target.stats()
        if let stats { monitor.observeHelperDrops(cumulative: stats.cumulativeDrops, at: now) }
        let s = monitor.snapshot(now: now)
        let v = HealthVerdict.evaluate(s)
        snapshot = s
        verdict = v
        helperStats = stats
        live = target.isLive()
        HealthDiagnostics.publish(Localization.english { HealthReport.summaryLine(s, HealthVerdict.evaluate(s)) })
    }

    var reportText: String {
        Localization.english {
            HealthReport.text(label: label, snapshot: snapshot, verdict: HealthVerdict.evaluate(snapshot),
                              helperFps: helperStats?.fps, helperBitrateKbps: helperStats?.bitrateKbps)
        }
    }
}

struct ConnectionHealthView: View {
    @ObservedObject var model: ConnectionHealthModel
    @State private var copied = false

    private var verdictColor: Color {
        switch model.verdict.level {
        case .healthy: return .green
        case .unstable: return .orange
        case .poor: return .red
        case .noData: return .gray
        }
    }

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Connection health").font(.title2.bold())
                    Text(model.label).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.reportText, forType: .string)
                        copied = true
                    }
                    if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                }

                verdictBanner

                if !model.live {
                    Text("This goggles window is not live yet. Figures appear once the picture is up.")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    tile(L("Frames per second"), String(format: "%.0f", s.fps))
                    tile(L("Bitrate"), String(format: "%.1f Mbps", s.bitrateMbps))
                    tile(L("Last frame"), s.secondsSinceLastFrame.map { L("%.1f s ago", $0) } ?? L("none"))
                    tile(L("Dropped / failed"), "\(s.drops) / \(s.decodeFailures)")
                }

                chartCard(L("Frames per second"), unit: "fps", color: .green, points: points { Double($0.frames) })
                chartCard(L("Video bitrate"), unit: "Mbps", color: .cyan, points: points { $0.megabitsPerSecond })
                chartCard(L("Longest frame gap each second"), unit: "ms", color: .orange, points: points { $0.maxGapMs })
                chartCard(L("Decode latency"), unit: "ms", color: .purple, points: s.series.compactMap { b in b.latencyMs.map { (b.secondsAgo, $0) } })
                problemsCard
                histogramCard

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Frame gap p50 / p95 / max").foregroundStyle(.secondary); Text("\(ms(s.gapP50Ms)) / \(ms(s.gapP95Ms)) / \(ms(s.gapMaxMs))") }
                    GridRow { Text("Gaps over 100 / 250 / 500 ms").foregroundStyle(.secondary); Text("\(s.stalls100) / \(s.stalls250) / \(s.stalls500)") }
                    GridRow { Text("Decode latency avg / p95").foregroundStyle(.secondary); Text("\(ms(s.latencyMs)) / \(ms(s.latencyP95Ms))") }
                    GridRow {
                        Text("Parameter sets").foregroundStyle(.secondary)
                        Text("\(s.parameterSets)" + (s.parameterSetIntervalMs.map { L(", every %.1f s", $0 / 1000) } ?? ""))
                    }
                    GridRow {
                        Text("Background service reports").foregroundStyle(.secondary)
                        Text(model.helperStats.map { String(format: "%d fps, %.0f kbps", $0.fps, $0.bitrateKbps) } ?? L("n/a"))
                    }
                }
                .font(.callout.monospacedDigit())

                Text(L("Covers the last %lld s (up to %lld s). USB error counts and resets are not reported by the background service, so they are not shown.", Int(s.spanSeconds.rounded()), HealthMonitor.defaultWindowSeconds))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? L("n/a") }

    private func points(_ value: @escaping (HealthBucket) -> Double) -> [(Int, Double)] {
        model.snapshot.series.map { ($0.secondsAgo, value($0)) }
    }

    private var verdictBanner: some View {
        let v = model.verdict
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(verdictColor).frame(width: 12, height: 12).accessibilityHidden(true)
                Text(v.level.title).font(.headline)
            }
            ForEach(v.reasons, id: \.self) { Text($0).font(.callout) }
            if !v.suggestions.isEmpty {
                Text("What to try").font(.subheadline.bold()).padding(.top, 2)
                ForEach(Array(v.suggestions.enumerated()), id: \.offset) { i, tip in
                    Text(verbatim: "\(i + 1). \(tip)").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(verdictColor.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
    }

    private func chartCard(_ title: String, unit: String, color: Color, points: [(Int, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let last = points.last { Text(String(format: "%.1f %@", last.1, unit)).font(.caption.monospacedDigit()) }
            }
            if points.count < 2 {
                Text("Collecting…").font(.caption2).foregroundStyle(.secondary).frame(height: 44)
            } else {
                Chart(points, id: \.0) { p in
                    LineMark(x: .value("Seconds ago", -p.0), y: .value(unit, p.1)).foregroundStyle(color)
                    AreaMark(x: .value("Seconds ago", -p.0), y: .value(unit, p.1)).foregroundStyle(color.opacity(0.15))
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) }
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 56)
            }
        }
    }

    private var problemsCard: some View {
        let series = model.snapshot.series
        return VStack(alignment: .leading, spacing: 4) {
            Text("Dropped or failed frames per second").font(.caption).foregroundStyle(.secondary)
            if series.count < 2 {
                Text("Collecting…").font(.caption2).foregroundStyle(.secondary).frame(height: 44)
            } else {
                Chart(series, id: \.secondsAgo) { b in
                    BarMark(x: .value("Seconds ago", -b.secondsAgo), y: .value("Problems", b.problems)).foregroundStyle(.red)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) }
                .frame(height: 44)
            }
        }
    }

    private var histogramCard: some View {
        let bins = Array(model.snapshot.histogram.enumerated())
        return VStack(alignment: .leading, spacing: 4) {
            Text("Frame gap distribution (ms)").font(.caption).foregroundStyle(.secondary)
            Chart(bins, id: \.offset) { b in
                BarMark(x: .value("Gap", HealthReport.binLabel(b.offset)), y: .value("Frames", b.element)).foregroundStyle(.teal)
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) }
            .frame(height: 70)
        }
    }
}
#endif
