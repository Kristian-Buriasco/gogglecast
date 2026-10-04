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
        .onAppear { apply() }
        .onChange(of: enabled) { _ in apply() }
        .onChange(of: port) { _ in if enabled { apply() } }
        .onChange(of: lan) { _ in if enabled { apply() } }
        .onChange(of: token) { _ in if enabled { apply() } }
        .onDisappear { session.removeConsumer(server); server.stop() }
    }

    private func apply() {
        if enabled {
            session.addConsumer(server)
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
            TextField("Port", value: $port, format: .number.grouping(.never))
            Toggle("Allow other devices on the network", isOn: $lan)
            HStack {
                TextField("Access token (optional)", text: $token)
                Button("Generate") {
                    token = (0..<16).map { _ in String(UInt8.random(in: 0...255), radix: 16) }.map { $0.count == 1 ? "0" + $0 : $0 }.joined()
                }
            }
            HStack {
                Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Text("Security: there is no authentication or encryption (plain HTTP). Anyone who can reach this port, and knows the token if set, can watch your feed. Keep it off on untrusted networks. Off by default; listens on localhost unless 'Allow other devices' is on. The token is sent in the URL and is not secret against network sniffing.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Safari and iOS play the page directly. Other browsers: open the URL's live.m3u8 in VLC. Expect ~4-8 s latency (2 s segments).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
