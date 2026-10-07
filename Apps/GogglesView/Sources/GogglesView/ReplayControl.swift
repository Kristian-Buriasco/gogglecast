import SwiftUI

/// Instant-replay button. Owns the `ReplayBuffer` lifecycle: it is a `DecodeSession`
/// consumer only while `replayEnabled` is on and the view is on screen.
struct ReplayControl: View {
    let session: DecodeSession
    @StateObject private var buffer = ReplayBuffer()
    @AppStorage(ReplayPrefs.enabledKey) private var enabled = false
    @AppStorage(ReplayPrefs.secondsKey) private var seconds = 30
    // Observed only so the control updates when the encoder setting changes.
    @AppStorage(ReencodePrefs.enabledKey) private var reencode = true
    @State private var toast: String?

    init(session: DecodeSession) { self.session = session }

    var body: some View {
        Group {
            if enabled && !available {
                Image(systemName: "gobackward")
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .help(ReplayPrefs.unavailableMessage)
                    .accessibilityLabel("Instant replay unavailable")
                    .accessibilityValue(ReplayPrefs.unavailableMessage)
                    .accessibilityIdentifier("replayButton")
            } else if enabled {
                HStack(spacing: 6) {
                    Button { save() } label: { Image(systemName: "gobackward") }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                        .help("Save last \(seconds)s (\(Int(buffer.bufferedSeconds))s buffered)")
                        .disabled(buffer.bufferedSeconds < 1)
                        .accessibilityLabel("Save instant replay")
                        .accessibilityValue("\(Int(buffer.bufferedSeconds)) seconds buffered")
                        .accessibilityIdentifier("replayButton")
                    if let toast { Text(toast).font(.caption).lineLimit(1) }
                }
            }
        }
        .onAppear { sync() }
        .onDisappear { session.removeConsumer(buffer); buffer.clear() }
        .onChange(of: enabled) { _, _ in sync() }
        .onChange(of: reencode) { _, _ in sync() }
        .onChange(of: seconds) { _, _ in buffer.setSeconds(clamped) }
        .onReceive(NotificationCenter.default.publisher(for: .gogglesSaveReplay)) { n in
            guard GlobalHotkeyRouting.shouldHandle(n, session: session) else { return }
            if enabled && available && buffer.bufferedSeconds >= 1 { save() }
        }
    }

    private var clamped: Int { min(max(seconds, ReplayPrefs.secondsRange.lowerBound), ReplayPrefs.secondsRange.upperBound) }

    private var available: Bool { _ = reencode; return ReplayPrefs.isAvailable }

    private func sync() {
        if enabled && available {
            buffer.setSeconds(clamped)
            session.addKeyframeSafeConsumer(buffer)
        } else {
            session.removeConsumer(buffer)
            buffer.clear()
        }
    }

    private func save() {
        OutputActivityBoard.shared.beginBusy()
        buffer.save { url in
            OutputActivityBoard.shared.endBusy()
            if let url { NotificationCenter.default.post(name: .gogglesReplaySaved, object: session, userInfo: ["path": url.path]) }
            show(url.map { "Saved \($0.lastPathComponent)" } ?? (buffer.lastError ?? "Save failed"))
        }
    }

    private func show(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if toast == s { toast = nil } }
    }
}

/// Toggle + window length, for the Settings window.
struct ReplaySettingsSection: View {
    @AppStorage(ReplayPrefs.enabledKey) private var enabled = false
    @AppStorage(ReplayPrefs.secondsKey) private var seconds = 30
    @AppStorage(ReencodePrefs.enabledKey) private var reencode = true
    @AppStorage(ReencodePrefs.bitrateKey) private var bitrate = ReencodePrefs.defaultBitrate

    private var caption: String {
        if !(reencode || OutputProcessor.isActive) { return ReplayPrefs.unavailableMessage }
        let real = ReplayPrefs.achievableSeconds(requested: seconds, bitrateMbps: bitrate)
        let cap = ReplayBuffer.byteCap / (1024 * 1024)
        let window = real < seconds ? "At \(bitrate) Mbps the buffer holds about \(real) s, not \(seconds) s. " : ""
        return window + "The buffer lives in memory and uses up to \(cap) MB while replay is on."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instant replay").font(.headline)
            Toggle("Keep a replay buffer (⇧⌘P saves it)", isOn: $enabled)
            Stepper("Window: \(seconds) s", value: $seconds, in: ReplayPrefs.secondsRange, step: 5)
                .disabled(!enabled)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
