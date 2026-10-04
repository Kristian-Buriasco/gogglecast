#if canImport(AppKit)
import AppKit
import SwiftUI
import IOKit
import CoreMedia
import Combine
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Benchmark / latency mode: the window. Runs a `BenchmarkRecorder` against
// the session app-level commands act on (`BenchmarkRouting`), shows the
// summary, and copies/saves the report. Opened from Settings > Advanced
// (`BenchmarkSettingsSection`). See docs/latency.md.
// ─────────────────────────────────────────────────────────────────────────

extension BenchmarkTarget {
    init(session: GogglesSession) {
        let coordinator = session.coordinator
        let decode = session.decodeSession
        self.init(
            label: session.label,
            decodeSession: decode,
            isLive: { [weak coordinator] in coordinator?.uiState == .live },
            stats: { [weak coordinator] in coordinator?.stats },
            environment: { [weak coordinator, weak decode] in
                BenchmarkEnvironmentProbe.collect(info: coordinator?.deviceInfo, dimensions: decode?.dimensions)
            }
        )
    }
}

enum BenchmarkEnvironmentProbe {
    static func collect(info: DeviceInfo?, dimensions: CMVideoDimensions?) -> BenchmarkEnvironment {
        let bundle = Bundle.main.infoDictionary ?? [:]
        return BenchmarkEnvironment(
            appVersion: "\(bundle["CFBundleShortVersionString"] as? String ?? "unknown") (build \(bundle["CFBundleVersion"] as? String ?? "unknown"))",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: DiagnosticsReport.sysctlString("hw.model"),
            cpuArch: DiagnosticsReport.cpuArch(),
            gogglesModel: info?.product,
            gogglesSerial: info?.serial.map(DiagnosticsReport.redactSerial),
            usbLinkSpeed: info.flatMap { usbLinkSpeed(vendor: $0.idVendor, product: $0.idProduct, serial: $0.serial) },
            usbDevice: info.map { USBLinkSpeed.deviceSummary(vendor: $0.idVendor, product: $0.idProduct, bus: $0.bus, address: $0.address, bcdDevice: $0.bcdDevice) },
            resolution: dimensions.map { "\($0.width)x\($0.height)" }
        )
    }

    /// Looks the goggles up in the IORegistry (IOUSBHostDevice by VID/PID,
    /// serial when known) and reads the negotiated link speed.
    static func usbLinkSpeed(vendor: UInt16, product: UInt16, serial: String?) -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        matching["idVendor"] = Int(vendor)
        matching["idProduct"] = Int(product)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var fallback: String?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            let speed = USBLinkSpeed.describe(properties: dict)
            let entrySerial = (dict["USB Serial Number"] ?? dict["kUSBSerialNumberString"]) as? String
            if let serial, !serial.isEmpty, entrySerial == serial { return speed }
            if fallback == nil { fallback = speed }
        }
        return fallback
    }
}

struct BenchmarkView: View {
    @StateObject private var recorder = BenchmarkRecorder()
    @AppStorage("benchmarkSeconds") private var seconds = BenchmarkRecorder.defaultSeconds
    @State private var target: BenchmarkTarget?
    @State private var live = false
    @State private var copied = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Benchmark").font(.title2.bold())
            Text("Measures frame pacing, helper-to-display latency, bitrate and this app's CPU/memory on the live stream. Leave the stream running and avoid other heavy work during the run.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Duration", selection: $seconds) {
                    ForEach(BenchmarkRecorder.durations, id: \.self) { Text("\($0) s").tag($0) }
                }
                .frame(width: 160)
                .disabled(recorder.phase == .running)
                if recorder.phase == .running {
                    Button("Cancel") { recorder.cancel() }
                } else {
                    Button("Run") {
                        guard let target else { return }
                        copied = false
                        recorder.start(target: target, seconds: seconds)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!live)
                }
                Spacer()
            }

            if !live && recorder.phase != .running {
                Text(target == nil ? "No goggles window is open. Open your goggles and wait for the live picture." : "\(target!.label) is not live. Wait for the picture, then run.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if recorder.phase == .running {
                ProgressView(value: recorder.progress)
                Text("\(recorder.liveFrames) frames so far").font(.caption).foregroundStyle(.secondary)
            }

            if let result = recorder.result {
                summary(result)
                HStack {
                    Button("Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BenchmarkReport.text(result), forType: .string)
                        copied = true
                    }
                    Button("Save as JSON…") { save(result) }
                    if copied { Text("Copied").foregroundStyle(.secondary) }
                }
                ScrollView {
                    Text(BenchmarkReport.text(result))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 560, height: 600, alignment: .top)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
        .onDisappear { recorder.cancel() }
    }

    private func refresh() {
        guard recorder.phase != .running else { return }
        target = BenchmarkRouting.targetProvider?()
        live = target?.isLive() ?? false
    }

    private func summary(_ r: BenchmarkResult) -> some View {
        let t = r.frameTiming
        func f(_ v: Double?, _ d: Int = 1) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "n/a" }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { Text("FPS avg / 1% low / min").foregroundStyle(.secondary); Text("\(f(t.fpsAverage)) / \(f(t.fpsOnePercentLow)) / \(f(t.fpsMinimum, 0))") }
            GridRow { Text("Jitter / stalls").foregroundStyle(.secondary); Text("\(f(t.jitterMs, 2)) ms / \(t.stalls)") }
            GridRow { Text("Latency p50 / p95 / p99").foregroundStyle(.secondary); Text("\(f(r.latencyMs?.p50, 2)) / \(f(r.latencyMs?.p95, 2)) / \(f(r.latencyMs?.p99, 2)) ms") }
            GridRow { Text("Bitrate").foregroundStyle(.secondary); Text("\(f(r.bitrateMbps, 2)) Mbps") }
            GridRow { Text("CPU avg / memory peak").foregroundStyle(.secondary); Text("\(f(r.cpuAveragePercent))% / \(f(r.memoryPeakMB)) MB") }
        }
        .font(.callout.monospacedDigit())
    }

    private func save(_ result: BenchmarkResult) {
        guard let data = try? BenchmarkReport.json(result) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GogglesView-benchmark-\(DiagnosticsReport.timestamp(result.startedAt)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum BenchmarkWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: BenchmarkView())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "GogglesView Benchmark"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 560, height: 600))
        w.isReleasedWhenClosed = false
        w.center()
        // Drop the hosting controller on close so onDisappear cancels a running benchmark.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            window?.contentViewController = nil
            window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
#endif
