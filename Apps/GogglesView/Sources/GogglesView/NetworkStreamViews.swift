import SwiftUI

/// Small toolbar toggle. Owns the streamer and its consumer registration.
struct NetworkStreamControl: View {
    let session: DecodeSession
    @StateObject private var streamer = NetworkStreamer()
    @AppStorage(NetStreamPrefs.autoStartKey) private var autoStart = false
    @State private var mbps: Double = 0
    @State private var lastBytes: UInt64 = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                if streamer.isStreaming { Text(String(format: "%.1f Mbps", mbps)).monospacedDigit() }
            }
            .foregroundStyle(streamer.lastError != nil ? Color.orange : (streamer.isStreaming ? Color.green : Color.primary))
        }
        .help(streamer.lastError ?? (streamer.isStreaming
              ? "Streaming to udp://\(NetStreamPrefs.host):\(NetStreamPrefs.port)" : "Start network stream"))
        .accessibilityLabel("Network stream")
        .accessibilityValue(streamer.lastError ?? (streamer.isStreaming ? String(format: "Streaming, %.1f megabits per second", mbps) : "Stopped"))
        .accessibilityIdentifier("networkStreamButton")
        .onReceive(tick) { _ in
            mbps = Double(streamer.bytesSent &- lastBytes) * 8 / 1_000_000
            lastBytes = streamer.bytesSent
        }
        .onAppear {
            SessionControlBoard.shared.register(streamer: streamer, for: session)
            if autoStart { start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gogglesToggleNetworkStream)) { n in
            guard GlobalHotkeyRouting.shouldHandle(n, session: session) else { return }
            toggle()
        }
        .onDisappear { stop() }
    }

    private func toggle() { streamer.isStreaming ? stop() : start() }

    private func start() {
        session.addConsumer(streamer)
        lastBytes = 0
        streamer.start(host: NetStreamPrefs.host, port: NetStreamPrefs.port)
    }

    private func stop() {
        session.removeConsumer(streamer)
        streamer.stop()
        mbps = 0
    }
}

struct NetworkStreamSettingsSection: View {
    @AppStorage(NetStreamPrefs.hostKey) private var host = "127.0.0.1"
    @AppStorage(NetStreamPrefs.portKey) private var port = 5000
    @AppStorage(NetStreamPrefs.autoStartKey) private var autoStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network Streaming").font(.headline)
            TextField("Host (unicast or multicast)", text: $host)
            TextField("Port", value: $port, format: .number.grouping(.never))
            Toggle("Start automatically", isOn: $autoStart)
            Text("Receiver: udp://@:\(String(port)) (OBS Media Source / VLC). Change applies on next start. Source resolution and bitrate are passed through unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
