import SwiftUI
import AppKit

enum VersionComparator {
    /// Numeric components of "v0.2.1" / "0.2-beta" -> [0, 2, 1]; nil if no leading number.
    static func components(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        t = String(t.prefix { $0 != "-" && $0 != "+" })
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.map { $0! }
    }

    /// True when `remote` is strictly newer than `local`. Missing components count as 0; unparseable -> false.
    static func isNewer(remote: String, than local: String) -> Bool {
        guard var r = components(remote), var l = components(local) else { return false }
        let n = max(r.count, l.count)
        r += Array(repeating: 0, count: n - r.count)
        l += Array(repeating: 0, count: n - l.count)
        return l.lexicographicallyPrecedes(r)
    }
}

enum UpdateCheckResult: Equatable {
    case upToDate(String)
    case available(tag: String, url: URL)
    case failed
}

enum UpdatePrefs {
    static let enabledKey = "updateCheckEnabled"
    static let tokenKey = "githubToken"
    static let lastCheckKey = "updateLastCheck"
    static let endpoint = URL(string: "https://api.github.com/repos/Kristian-Buriasco/gogglecast/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Kristian-Buriasco/gogglecast/releases")!
}

final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var result: UpdateCheckResult?
    @Published private(set) var checking = false
    @Published private(set) var latestAsset: UpdateAsset?

    /// Only set by `--settings-shot`, which runs outside an app bundle.
    static var versionOverride: String?

    static var currentVersion: String {
        versionOverride ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Pure: classify a GitHub "latest release" response.
    static func interpret(status: Int, data: Data, current: String) -> UpdateCheckResult {
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return .failed }
        if VersionComparator.isNewer(remote: tag, than: current) {
            let url = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? UpdatePrefs.releasesPage
            return .available(tag: tag, url: url)
        }
        return .upToDate(tag)
    }

    func check() {
        guard !checking else { return }
        checking = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdatePrefs.lastCheckKey)
        var req = URLRequest(url: UpdatePrefs.endpoint, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let t = SecretStore.get(UpdatePrefs.tokenKey)
        if !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") // never logged
        }
        let current = Self.currentVersion
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r = data.map { Self.interpret(status: status, data: $0, current: current) } ?? .failed
            let asset = data.flatMap { UpdateAsset.from(releaseJSON: $0) }
            DispatchQueue.main.async {
                self.result = r; self.latestAsset = asset; self.checking = false
                if case .available(let tag, _) = r, let asset, UserDefaults.standard.bool(forKey: UpdatePrefs2.autoInstallKey) {
                    UpdateInstaller.shared.stage(asset: asset, version: tag)
                }
            }
        }.resume()
    }

    /// Launch hook: at most once per 24 h, and only when the user opted in.
    func checkOnLaunchIfDue(now: Date = Date()) {
        let d = UserDefaults.standard
        let on = d.object(forKey: UpdatePrefs.enabledKey) as? Bool ?? true
        guard on || d.bool(forKey: UpdatePrefs2.autoInstallKey) else { return }
        let last = d.double(forKey: UpdatePrefs.lastCheckKey)
        if now.timeIntervalSince1970 - last >= 24 * 3600 { check() }
    }
}

struct UpdateSettingsSection: View {
    @AppStorage(UpdatePrefs.enabledKey) private var enabled = true
    @AppStorage(UpdatePrefs2.autoInstallKey) private var autoInstall = false
    @ObservedObject private var checker = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared

    private var status: String {
        if case .failed(let m) = installer.state { return m }
        if case .downloading = installer.state { return "Downloading and verifying the update…" }
        switch checker.result {
        case nil: return "Version \(UpdateChecker.currentVersion)"
        case .upToDate: return "You're up to date (version \(UpdateChecker.currentVersion))."
        case .available(let t, _): return "\(t) is available. You have \(UpdateChecker.currentVersion)."
        case .failed: return "Couldn't check for updates."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates").font(.headline)
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                primaryButton
                if case .available(_, let url) = checker.result {
                    Button("Release notes") { NSWorkspace.shared.open(url) }
                }
            }
            Toggle("Check for updates daily", isOn: $enabled)
            Toggle("Install updates automatically", isOn: $autoInstall)
            Text("Updates are downloaded from this project's GitHub releases, checked against their SHA-256 and code signature, and applied when you quit (or when you choose Install & Restart). Never while recording or streaming.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch installer.state {
        case .staged(let v):
            Button("Install \(v) & Restart") {
                if installer.isRecordingNow() { return }
                installer.installAndRestart()
            }
            .buttonStyle(.borderedProminent)
            .disabled(installer.isRecordingNow())
        case .downloading:
            ProgressView().controlSize(.small)
        default:
            if case .available(let tag, _) = checker.result, let asset = checker.latestAsset {
                Button("Download \(tag)") { installer.stage(asset: asset, version: tag) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Check Now") { checker.check() }.disabled(checker.checking)
            }
        }
    }
}
