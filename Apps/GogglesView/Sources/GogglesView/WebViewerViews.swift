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

    private var url: String {
        WebViewerPrefs.viewerURL(host: lan ? WebViewerPrefs.localHostname : "localhost",
                                 port: (1...65535).contains(port) ? port : 8080, token: token)
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
            HStack {
                Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Text("Security: there is no encryption (plain HTTP). Anyone who can reach this port and knows the token can watch your feed. Requests whose Host header is not this Mac (localhost, its .local name or its IP addresses) are refused, which blocks DNS-rebinding from web pages. Keep it off on untrusted networks. Off by default; listens on localhost unless 'Allow other devices' is on. The token is sent in the URL and is not secret against network sniffing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Safari and iOS play the page directly. Other browsers: open the URL's live.m3u8 in VLC. Expect ~4-8 s latency (2 s segments).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
