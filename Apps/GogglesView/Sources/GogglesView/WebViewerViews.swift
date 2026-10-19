import SwiftUI
import AppKit

/// Toolbar toggle for the local web viewer. The enabled flag lives in prefs so the
/// settings toggle and this button stay in sync; this view applies it to the server.
struct WebViewerControl: View {
    let session: DecodeSession
    @StateObject private var server = WebViewerServer()
    @AppStorage(WebViewerPrefs.enabledKey) private var enabled = false
    @AppStorage(WebViewerPrefs.portKey) private var port = WebViewerPrefs.defaultPort
    @AppStorage(WebViewerPrefs.lanKey) private var lan = false
    @KeychainSecret(WebViewerPrefs.tokenKey) private var token

    var body: some View {
        Button { enabled.toggle() } label: {
            Image(systemName: "safari")
                .foregroundStyle(server.lastError != nil ? Color.orange : server.isRunning ? Color.green : Color.primary)
        }
        .help(server.lastError ?? (server.isRunning ? L("Web viewer on port %lld", port) : L("Start web viewer")))
        .accessibilityLabel("Web viewer")
        .accessibilityValue(server.lastError ?? (server.isRunning ? L("Running on port %lld", port) : L("Stopped")))
        .onAppear { apply(justEnabled: false) }
        .onChange(of: enabled) { old, new in apply(justEnabled: new && !old) }
        .onChange(of: port) { _, _ in if enabled { apply(justEnabled: false) } }
        .onChange(of: lan) { _, _ in if enabled { apply(justEnabled: false) } }
        .onChange(of: token) { old, _ in if enabled, !old.isEmpty { apply(justEnabled: false) } } // "" -> loaded value is not an edit
        .onDisappear { session.removeConsumer(server); server.stop() }
    }

    /// `justEnabled` is true only for a real off-to-on change of the viewer, which is the only
    /// moment the overlay hint may appear (not on appear, nor when the token or port is edited).
    private func apply(justEnabled: Bool) {
        if enabled {
            var tok = _token.load()
            // An empty token is only acceptable in localhost-only mode; generate one when the viewer is
            // switched on (or whenever other devices are allowed) so the feed is never open by accident.
            if tok.isEmpty, justEnabled || lan {
                tok = WebViewerPrefs.existingOrNewToken()
                token = tok
            }
            if justEnabled { OverlayHint.noteStarted(.output) }
            session.addKeyframeSafeConsumer(server)
            server.start(port: WebViewerPrefs.port, allowLAN: lan, token: tok)
        } else {
            session.removeConsumer(server)
            server.stop()
        }
    }
}

struct WebViewerSettingsSection: View {
    @AppStorage(WebViewerPrefs.enabledKey) private var enabled = false
    @AppStorage(WebViewerPrefs.portKey) private var port = WebViewerPrefs.defaultPort
    @AppStorage(WebViewerPrefs.lanKey) private var lan = false
    @KeychainSecret(WebViewerPrefs.tokenKey) private var token

    private var effectivePort: Int { (1...65535).contains(port) ? port : WebViewerPrefs.defaultPort }

    private var url: String {
        WebViewerPrefs.viewerURL(host: lan ? WebViewerPrefs.localHostname : "localhost", port: effectivePort, token: token)
    }

    private func urlRow(_ value: String, label: String) -> some View {
        SettingsRow(LocalizedStringKey(label), indented: true) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .accessibilityLabel(L("Copy %@ URL", label))
        }
    }

    var body: some View {
        SettingsGroup("Web Viewer",
                      info: "Off by default. Anyone on your network can watch while it is on. There is no encryption (plain HTTP) and the token is sent in the URL, so keep it off on untrusted networks. It only listens on this Mac unless 'Allow other devices' is on.\n\nSafari on iPad, iPhone and Mac plays the page directly. Other browsers: open the URL's live.m3u8 in VLC. Latency comes from 1 s segments and Safari's start-up buffer; expect a few seconds behind live, not real time (not yet measured on hardware). The page shows its own estimate.") {
            SettingsToggleRow("Enable local web viewer", isOn: $enabled)
                .onChange(of: enabled) { old, new in
                    if new && !old && _token.load().isEmpty { token = WebViewerPrefs.existingOrNewToken() }
                }
            Group {
                SettingsRow("Port", indented: true) {
                    TextField("Port", value: $port, format: .number.grouping(.never)).labelsHidden()
                        .settingsField(width: 100, valid: (1...65535).contains(port))
                }
                SettingsToggleRow("Allow other devices on the network", isOn: $lan,
                                  help: LocalizedStringKey(lan ? L("A token is required while other devices are allowed.") : L("With the token empty only this Mac can connect, and only through localhost.")),
                                  indented: true)
                    .onChange(of: lan) { _, new in if new && _token.load().isEmpty { token = WebViewerPrefs.existingOrNewToken() } }
                SettingsRow("Access token", indented: true) {
                    SettingsSecretField(title: "Access token", text: $token, width: 160, onReveal: { _token.load() })
                    Button("Generate") { token = WebViewerPrefs.generateToken() }
                }
            }
            .disabled(!enabled)
            urlRow(url, label: lan ? L("This Mac (.local)") : L("This Mac"))
            if lan {
                if let ip = WebViewerAddress.preferredIPv4(from: WebHostPolicy.localAddresses()) {
                    let ipURL = WebViewerPrefs.viewerURL(host: ip, port: effectivePort, token: token)
                    urlRow(ipURL, label: L("IP address"))
                    SettingsRow("QR code", help: "Scan with the iPad or phone camera to open the viewer. The QR code contains the access token, so do not share a screenshot of it.",
                                info: "Scan with the iPad or phone camera to open the viewer. Safari there can use Share > Add to Home Screen for a full-screen app. The device must be on the same network. The QR code contains the access token, so do not share a screenshot of it.") {
                        if let qr = WebViewerQR.image(for: ipURL) {
                            Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                                .frame(width: 120, height: 120)
                                .accessibilityLabel("QR code of the viewer address")
                        }
                    }
                } else {
                    SettingsRow("IP address") {
                        Text("No local network address found. Connect this Mac to Wi-Fi or Ethernet.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                SettingsRow("QR code") {
                    Text("To watch on an iPad or phone, turn on 'Allow other devices on the network'. A QR code appears here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { if enabled { _token.load() } }
    }
}
