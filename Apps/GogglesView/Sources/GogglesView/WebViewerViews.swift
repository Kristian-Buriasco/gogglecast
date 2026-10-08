import SwiftUI
import AppKit

/// Toolbar toggle for the local web viewer. The enabled flag lives in prefs so the
/// settings toggle and this button stay in sync; this view applies it to the server.
struct WebViewerControl: View {
    let session: DecodeSession
    @StateObject private var server = WebViewerServer()
    @AppStorage(WebViewerPrefs.enabledKey) private var enabled = false
    @AppStorage(WebViewerPrefs.portKey) private var port = 8080
    @AppStorage(WebViewerPrefs.lanKey) private var lan = false
    @KeychainSecret(WebViewerPrefs.tokenKey) private var token

    var body: some View {
        Button { enabled.toggle() } label: {
            Image(systemName: "safari")
                .foregroundStyle(server.lastError != nil ? Color.orange : server.isRunning ? Color.green : Color.primary)
        }
        .help(server.lastError ?? (server.isRunning ? "Web viewer on port \(port)" : "Start web viewer"))
        .accessibilityLabel("Web viewer")
        .accessibilityValue(server.lastError ?? (server.isRunning ? "Running on port \(port)" : "Stopped"))
        .onAppear { apply(justEnabled: false) }
        .onChange(of: enabled) { old, new in apply(justEnabled: new && !old) }
        .onChange(of: port) { _, _ in if enabled { apply(justEnabled: false) } }
        .onChange(of: lan) { _, _ in if enabled { apply(justEnabled: false) } }
        .onChange(of: token) { _, _ in if enabled { apply(justEnabled: false) } }
        .onDisappear { session.removeConsumer(server); server.stop() }
    }

    /// `justEnabled` is true only for a real off-to-on change of the viewer, which is the only
    /// moment the overlay hint may appear (not on appear, nor when the token or port is edited).
    private func apply(justEnabled: Bool) {
        if enabled {
            // An empty token is only acceptable in localhost-only mode; generate one when the viewer is
            // switched on (or whenever other devices are allowed) so the feed is never open by accident.
            if token.isEmpty, justEnabled || lan {
                token = WebViewerPrefs.existingOrNewToken()
            }
            if justEnabled { OverlayHint.noteStarted(.output) }
            session.addKeyframeSafeConsumer(server)
            server.start(port: WebViewerPrefs.port, allowLAN: lan, token: token)
        } else {
            session.removeConsumer(server)
            server.stop()
        }
    }
}

struct WebViewerSettingsSection: View {
    @AppStorage(WebViewerPrefs.enabledKey) private var enabled = false
    @AppStorage(WebViewerPrefs.portKey) private var port = 8080
    @AppStorage(WebViewerPrefs.lanKey) private var lan = false
    @KeychainSecret(WebViewerPrefs.tokenKey) private var token

    private var effectivePort: Int { (1...65535).contains(port) ? port : 8080 }

    private var url: String {
        WebViewerPrefs.viewerURL(host: lan ? WebViewerPrefs.localHostname : "localhost", port: effectivePort, token: token)
    }

    private func urlRow(_ value: String, label: String) -> some View {
        HStack {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .accessibilityLabel("Copy \(label) URL")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Web Viewer").font(.headline)
            Toggle("Enable local web viewer", isOn: $enabled)
                .onChange(of: enabled) { old, new in
                    if new && !old && token.isEmpty { token = WebViewerPrefs.existingOrNewToken() }
                }
            TextField("Port", value: $port, format: .number.grouping(.never))
            Toggle("Allow other devices on the network", isOn: $lan)
                .onChange(of: lan) { _, new in if new && token.isEmpty { token = WebViewerPrefs.existingOrNewToken() } }
            HStack {
                TextField("Access token", text: $token)
                Button("Generate") { token = WebViewerPrefs.generateToken() }
            }
            Text(lan ? "A token is required while other devices are allowed." : "With the token empty only this Mac can connect, and only through localhost.")
                .font(.caption).foregroundStyle(.secondary)
            urlRow(url, label: lan ? "This Mac (.local)" : "This Mac")
            if lan {
                if let ip = WebViewerAddress.preferredIPv4(from: WebHostPolicy.localAddresses()) {
                    let ipURL = WebViewerPrefs.viewerURL(host: ip, port: effectivePort, token: token)
                    urlRow(ipURL, label: "IP address")
                    HStack(alignment: .top, spacing: 12) {
                        if let qr = WebViewerQR.image(for: ipURL) {
                            Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                                .frame(width: 140, height: 140)
                                .accessibilityLabel("QR code of the viewer address")
                        }
                        Text("Scan with the iPad or phone camera to open the viewer. Safari there can use Share > Add to Home Screen for a full-screen app. The device must be on the same network. The QR code contains the access token, so do not share a screenshot of it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No local network address found. Connect this Mac to Wi-Fi or Ethernet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("To watch on an iPad or phone, turn on 'Allow other devices on the network'. A QR code appears here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Off by default. Anyone on your network can watch while it is on. There is no encryption (plain HTTP) and the token is sent in the URL, so keep it off on untrusted networks. It only listens on this Mac unless 'Allow other devices' is on.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Safari on iPad, iPhone and Mac plays the page directly. Other browsers: open the URL's live.m3u8 in VLC. Latency comes from 1 s segments and Safari's start-up buffer; expect a few seconds behind live, not real time (not yet measured on hardware). The page shows its own estimate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
