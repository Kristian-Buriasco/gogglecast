#if canImport(AppKit)
import SwiftUI
import AppKit
import GogglesXPC

/// Sequential self-test with a throwaway `HelperClient`. The stream test is
/// opt-in: it claims the goggles for ~5 s, so it conflicts with an active
/// stream in the main window (go back to the device picker first).
final class SelfTestModel: ObservableObject {
    struct Row: Identifiable { let id: String; let title: String; var status: SetupChecklist.Status; var detail: String? }

    @Published var rows: [Row] = [
        Row(id: "registered", title: "Background service set up", status: .unknown, detail: nil),
        Row(id: "xpc", title: "Background service reachable and up to date", status: .unknown, detail: nil),
        Row(id: "usb", title: "Goggles enumerated on USB", status: .unknown, detail: nil),
    ]
    @Published var streamRow = Row(id: "stream", title: "Stream test", status: .unknown, detail: "Not run")
    @Published var running = false
    @Published var streaming = false

    private var client: HelperClient?
    private var deviceId: String?

    private func set(_ id: String, _ status: SetupChecklist.Status, _ detail: String?) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].status = status; rows[i].detail = detail }
    }

    func runChecks() {
        guard !running, !streaming else { return }
        running = true
        deviceId = nil
        for r in rows { set(r.id, .unknown, "Checking…") }

        let reg = HelperRegistration.status
        let ok = reg == .enabled
        set("registered", ok ? .pass : .fail, ok ? nil : HelperRegistration.plainDescription(reg))

        client?.onConnectionStateChange = nil
        client?.disconnect()
        let c = HelperClient()
        client = c
        c.onConnectionStateChange = { [weak self] state in
            guard let self, self.running, self.client === c else { return }
            switch state {
            case .connected:
                guard self.rows[1].status != .pass else { return }
                self.set("xpc", .pass, "Protocol version matches")
                self.enumerate(c)
            case .versionMismatch(let reported, let expected):
                self.set("xpc", .fail, "The background service is from a different version (\(reported), this app needs \(expected)). Set it up again in the setup assistant.")
                self.set("usb", .unknown, "Skipped")
                self.running = false
            case .connecting, .disconnected: break
            }
        }
        c.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.running, self.client === c, self.rows[1].status == .unknown else { return }
            self.set("xpc", .fail, "The background service did not answer in 5 s. Open the setup assistant.")
            self.set("usb", .unknown, "Skipped")
            self.running = false
        }
    }

    private func enumerate(_ c: HelperClient) {
        c.enumerateDevices { [weak self] infos in
            DispatchQueue.main.async {
                guard let self, self.client === c else { return }
                if let first = infos.first {
                    self.deviceId = first.deviceId
                    self.set("usb", .pass, "\(infos.count) device(s): \(first.product ?? "DJI Goggles")")
                } else {
                    self.set("usb", .fail, "None found. Enable OTG Wired Connection on the goggles, use a data cable.")
                }
                self.running = false
            }
        }
    }

    /// Opt-in: claim, wait for the first frame, measure fps over 5 s, then stop.
    func runStreamTest() {
        guard !running, !streaming, let c = client, let id = deviceId else { return }
        streaming = true
        streamRow = Row(id: "stream", title: "Stream test", status: .unknown, detail: "Claiming…")
        let session = DecodeSession()
        var meter = StreamTestMeter()
        let t0 = ProcessInfo.processInfo.systemUptime
        // NAL callbacks arrive on the main queue (see HelperClient), so `meter` is main-confined.
        c.onNALUnit = { data, nalType, isParameterSet, hostTime in
            session.handle(nalData: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
            if !isParameterSet { meter.recordFrame(at: ProcessInfo.processInfo.systemUptime) }
        }
        c.startStreaming(deviceId: id) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    self.streamRow.status = .fail
                    self.streamRow.detail = "Claim failed: \(error?.localizedDescription ?? "unknown")"
                    self.endStream(c, id)
                    return
                }
                self.streamRow.detail = "Measuring for 5 s…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let end = ProcessInfo.processInfo.systemUptime
                    if let first = meter.firstFrameAt, let fps = meter.fps(endingAt: end) {
                        self.streamRow.status = .pass
                        self.streamRow.detail = String(format: "First frame after %.1f s, %.1f fps", first - t0, fps)
                    } else {
                        self.streamRow.status = .fail
                        self.streamRow.detail = meter.gotFirstFrame ? "Too few frames to measure fps" : "No frames received"
                    }
                    self.endStream(c, id)
                }
            }
        }
    }

    private func endStream(_ c: HelperClient, _ id: String) {
        c.onNALUnit = nil
        c.stopStreaming(deviceId: id) { DispatchQueue.main.async { self.streaming = false } }
    }

    func teardown() {
        if streaming, let c = client, let id = deviceId { c.stopStreaming(deviceId: id) }
        client?.onNALUnit = nil
        client?.onConnectionStateChange = nil
        client?.disconnect()
        client = nil
        running = false
        streaming = false
    }
}

struct SelfTestView: View {
    @StateObject private var model = SelfTestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Self-test").font(.title2.bold())
            ForEach(model.rows) { row($0) }
            Button("Run checks") { model.runChecks() }.disabled(model.running || model.streaming)
            Divider()
            Text("Stream test (optional)").font(.headline)
            Text("Claims the goggles and streams for about 5 seconds to measure frame rate. Stop any active stream first (return to the device picker). Requires the checks above to pass.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row(model.streamRow)
            Button("Run stream test") { model.runStreamTest() }
                .disabled(model.running || model.streaming || model.rows[2].status != .pass)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 440, height: 400, alignment: .top)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onAppear { model.runChecks() }
        .onDisappear { model.teardown() }
    }

    private func row(_ r: SelfTestModel.Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.status == .pass ? "checkmark.circle.fill" : r.status == .fail ? "xmark.octagon.fill" : "circle.dotted")
                .foregroundStyle(r.status == .pass ? .green : r.status == .fail ? .red : .secondary)
                .accessibilityLabel(AccessibilityLabels.checkStatus(pass: r.status == .pass, fail: r.status == .fail))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.callout.weight(.medium))
                if let d = r.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

enum SelfTestWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: SelfTestView())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "GogglesView Self-test"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 440, height: 400))
        w.isReleasedWhenClosed = false
        w.center()
        // Drop the hosting controller on close so the view's onDisappear runs teardown (stops any stream).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            window?.contentViewController = nil
            window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Settings > General: open the self-test.
struct SelfTestSettingsSection: View {
    var body: some View {
        HStack {
            Button("Run self-test…") { SelfTestWindow.show() }
            Spacer()
        }
    }
}
#endif
