import SwiftUI
import AppKit

/// Toolbar toggle for SRT. Disabled (with a reason) when libsrt isn't installed.
struct SRTStreamControl: View {
    let session: DecodeSession
    @StateObject private var out = SRTOutput()
    @State private var available = SRTOutput.isAvailable()

    var body: some View {
        Button(action: toggle) {
            Text("SRT").font(.caption.weight(.semibold))
                .foregroundStyle(out.lastError != nil ? Color.orange
                                 : (out.connected ? Color.green : (out.isStreaming ? Color.yellow : Color.primary)))
        }
        .buttonStyle(.plain)
        .disabled(!available && !out.isStreaming)
        .accessibilityLabel("SRT stream")
        .accessibilityValue(AccessibilityLabels.streamState(isStreaming: out.isStreaming, connected: out.connected, error: out.lastError))
        .help(!available ? "libsrt not found (brew install srt, or set the path in Settings > Streaming)"
              : out.lastError ?? (out.isStreaming ? (out.connected ? "SRT connected" : "SRT waiting for peer") : "Start SRT stream"))
        .onAppear { available = SRTOutput.isAvailable() }
        .onDisappear { stop() }
    }

    private func toggle() { out.isStreaming ? stop() : start() }

    private func start() {
        session.addKeyframeSafeConsumer(out)
        out.start(mode: SRTPrefs.mode, host: SRTPrefs.host, port: SRTPrefs.port,
                  latencyMs: SRTPrefs.latencyMs, passphrase: SRTPrefs.passphrase)
        if !out.isStreaming { session.removeConsumer(out) }
    }

    private func stop() { session.removeConsumer(out); out.stop() }
}

struct SRTSettingsSection: View {
    @AppStorage(SRTPrefs.modeKey) private var mode = SRTMode.caller.rawValue
    @AppStorage(SRTPrefs.hostKey) private var host = "127.0.0.1"
    @AppStorage(SRTPrefs.portKey) private var port = 9000
    @AppStorage(SRTPrefs.latencyKey) private var latency = SRTPrefs.defaultLatency
    @KeychainSecret(SRTPrefs.passphraseKey) private var passphrase
    @AppStorage(SRTPrefs.libraryPathKey) private var libPath = ""

    var body: some View {
        let found = OutputLibrary.resolveSRT(userPath: libPath)
        let m = SRTMode(rawValue: mode) ?? .caller
        VStack(alignment: .leading, spacing: 6) {
            Text("SRT Output").font(.headline)
            Text(found.map { "libsrt: \($0)" } ?? "libsrt not found. Install with `brew install srt` or choose the library below. It is loaded at runtime only, never bundled.")
                .font(.caption).foregroundStyle(found == nil ? Color.orange : Color.secondary)
            LibraryPathRow(title: "libsrt path (optional)", path: $libPath)
            Picker("Mode", selection: $mode) {
                Text("Caller (connect to receiver)").tag(SRTMode.caller.rawValue)
                Text("Listener (wait for receiver)").tag(SRTMode.listener.rawValue)
            }
            if m == .caller { TextField("Receiver host", text: $host) }
            TextField("Port", value: $port, format: .number.grouping(.never))
            TextField("Latency (ms, 20-8000)", value: $latency, format: .number.grouping(.never))
            SecureField("Passphrase (10-79 chars, optional)", text: $passphrase)
            if !SRTPrefs.passphraseValid(passphrase) {
                Text("Passphrase must be 10-79 characters.").font(.caption).foregroundStyle(.orange)
            }
            Text(SRTPrefs.receiverHint(mode: m, port: SRTPrefs.clampPort(port), hasPassphrase: !passphrase.isEmpty))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Works with OBS, VLC and ffplay. Latency should be 3-4x the network RTT. Changes apply on next start.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NDIStreamControl: View {
    let session: DecodeSession
    @StateObject private var out = NDIOutput()
    @State private var available = NDIOutput.isAvailable()

    var body: some View {
        Button(action: toggle) {
            Text("NDI").font(.caption.weight(.semibold))
                .foregroundStyle(out.lastError != nil ? Color.orange : (out.isStreaming ? Color.green : Color.primary))
        }
        .buttonStyle(.plain)
        .disabled(!available && !out.isStreaming)
        .accessibilityLabel("NDI output")
        .accessibilityValue(AccessibilityLabels.streamState(isStreaming: out.isStreaming, connected: out.isStreaming, error: out.lastError))
        .help(!available ? "NDI runtime not found (install NDI Tools or the NDI SDK)"
              : out.lastError ?? (out.isStreaming ? "Sending NDI source \(NDIPrefs.sourceName)" : "Start NDI output (experimental)"))
        .onAppear { available = NDIOutput.isAvailable() }
        .onDisappear { stop() }
    }

    private func toggle() { out.isStreaming ? stop() : start() }

    private func start() {
        session.addKeyframeSafeConsumer(out)
        out.start(sourceName: NDIPrefs.sourceName)
        if !out.isStreaming { session.removeConsumer(out) }
    }

    private func stop() { session.removeConsumer(out); out.stop() }
}

struct NDISettingsSection: View {
    @AppStorage(NDIPrefs.sourceNameKey) private var name = "GogglesView"
    @AppStorage(NDIPrefs.libraryPathKey) private var libPath = ""
    @AppStorage(NDIPrefs.unverifiedAckKey) private var ack = false

    var body: some View {
        let found = OutputLibrary.resolveNDI(userPath: libPath)
        VStack(alignment: .leading, spacing: 6) {
            Text("NDI Output (experimental)").font(.headline)
            Text(found.map { "NDI runtime: \($0)" } ?? "NDI runtime not found. Install NDI Tools / the NDI SDK or choose libndi.dylib below. It is loaded at runtime only, never bundled.")
                .font(.caption).foregroundStyle(found == nil ? Color.orange : Color.secondary)
            LibraryPathRow(title: "libndi.dylib path (optional)", path: $libPath)
            TextField("Source name", text: $name)
            Toggle("I accept the unverified NDI ABI (may crash)", isOn: $ack).disabled(found == nil)
            Text("The NDI struct layouts were written without the SDK headers to check against. Video is decoded to UYVY and sent as-is (CPU cost, small added latency).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct LibraryPathRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        HStack {
            TextField(title, text: $path)
            Button("Choose…") {
                let p = NSOpenPanel()
                p.canChooseFiles = true; p.canChooseDirectories = false
                if p.runModal() == .OK, let u = p.url { path = u.path }
            }
        }
    }
}
