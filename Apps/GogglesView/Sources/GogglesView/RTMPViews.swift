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
        .accessibilityLabel("RTMP stream")
        .accessibilityValue(publisher.lastError ?? (publisher.isLive ? L("Live") : publisher.isStreaming ? L("Connecting") : L("Stopped")))
        .onAppear { if autoStart { start() } }
        .onDisappear { stop() }
    }

    private func toggle() { publisher.isStreaming ? stop() : start() }

    private func start() {
        OverlayHint.noteStarted(.output)
        session.addKeyframeSafeConsumer(publisher)
        publisher.start(url: RTMPPrefs.url, streamKey: RTMPPrefs.streamKey)
    }

    private func stop() {
        session.removeConsumer(publisher)
        publisher.stop()
    }
}

struct RTMPSettingsSection: View {
    @AppStorage(RTMPPrefs.urlKey) private var url = ""
    @KeychainSecret(RTMPPrefs.streamKeyKey) private var key
    @AppStorage(RTMPPrefs.autoStartKey) private var autoStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RTMP Push (Twitch / YouTube / custom)").font(.headline)
            TextField("Server URL", text: $url, prompt: Text("rtmp://live.twitch.tv/app"))
            SecureField("Stream key", text: $key)
            Toggle("Start automatically", isOn: $autoStart)
            Text("The stream key is stored in the macOS Keychain and is never logged. Changes apply on next start.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Twitch and YouTube prefer 8 Mbps or less with a keyframe every 2 s. Goggles video is passed through unchanged, so the stream may be rejected or look worse. Not yet tested against a live service.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
