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

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
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
            DispatchQueue.main.async { self.result = r; self.checking = false }
        }.resume()
    }

    /// Launch hook: at most once per 24 h, and only when the user opted in.
    func checkOnLaunchIfDue(now: Date = Date()) {
        let d = UserDefaults.standard
        guard d.bool(forKey: UpdatePrefs.enabledKey) else { return }
        let last = d.double(forKey: UpdatePrefs.lastCheckKey)
        if now.timeIntervalSince1970 - last >= 24 * 3600 { check() }
    }
}

struct UpdateSettingsSection: View {
    @AppStorage(UpdatePrefs.enabledKey) private var enabled = false
    @ObservedObject private var checker = UpdateChecker.shared

    private var status: String {
        switch checker.result {
        case nil: return "Current version \(UpdateChecker.currentVersion)."
        case .upToDate(let t): return "You're up to date (latest: \(t))."
        case .available(let t, _): return "Update available: \(t) (you have \(UpdateChecker.currentVersion))."
        case .failed: return "Couldn't check for updates"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Updates").font(.headline)
            Toggle("Check for updates daily at launch", isOn: $enabled)
            HStack {
                Button("Check now") { checker.check() }.disabled(checker.checking)
                if case .available(_, let url) = checker.result {
                    Button("View release") { NSWorkspace.shared.open(url) }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }
}
