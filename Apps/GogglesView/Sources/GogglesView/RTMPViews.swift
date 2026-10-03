import SwiftUI

/// Toolbar toggle for the RTMP push. Owns the publisher and its consumer registration.
struct RTMPStreamControl: View {
    let session: DecodeSession
    @StateObject private var publisher = RTMPPublisher()
    @AppStorage(RTMPPrefs.autoStartKey) private var autoStart = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(publisher.lastError != nil ? Color.orange
                                 : publisher.isLive ? Color.red
                                 : publisher.isStreaming ? Color.yellow : Color.primary)
        }
        .help(publisher.lastError.map { "RTMP: \($0)" } ?? "RTMP: \(publisher.status)")
        .onAppear { if autoStart { start() } }
        .onDisappear { stop() }
    }

    private func toggle() { publisher.isStreaming ? stop() : start() }

    private func start() {
        session.addConsumer(publisher)
        publisher.start(url: RTMPPrefs.url, streamKey: RTMPPrefs.streamKey)
    }

    private func stop() {
        session.removeConsumer(publisher)
        publisher.stop()
    }
}

struct RTMPSettingsSection: View {
    @AppStorage(RTMPPrefs.urlKey) private var url = ""
    @AppStorage(RTMPPrefs.streamKeyKey) private var key = ""
    @AppStorage(RTMPPrefs.autoStartKey) private var autoStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RTMP Push (Twitch / YouTube / custom)").font(.headline)
            TextField("Server URL", text: $url, prompt: Text("rtmp://live.twitch.tv/app"))
            SecureField("Stream key", text: $key)
            Toggle("Start automatically", isOn: $autoStart)
            Text("The stream key is stored unencrypted in this app's preferences and is never logged. Changes apply on next start.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The goggles' H.264 stream is passed through untouched: its bitrate (~10-20 Mbps) and keyframe interval cannot be changed. Twitch and YouTube typically want at most ~8 Mbps and a 2 s keyframe interval, so the ingest may reject or degrade it. Untested against a real ingest; use a self-hosted RTMP server for best results.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
