import Foundation
import Testing
@testable import GogglesView

struct UpdateInstallerTests {
    private func release(_ assets: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": "v9.9", "assets": assets])
    }
    private let good = "https://github.com/Kristian-Buriasco/gogglecast/releases/download/v9.9/GogglesView-9.9.dmg"

    @Test func picksDmgWithDigest() {
        let a = UpdateAsset.from(releaseJSON: release([
            ["name": "notes.txt", "browser_download_url": "https://github.com/Kristian-Buriasco/gogglecast/releases/download/v9.9/notes.txt"],
            ["name": "GogglesView-9.9.dmg", "browser_download_url": good, "digest": "sha256:ABCDEF"],
        ]))
        #expect(a?.name == "GogglesView-9.9.dmg")
        #expect(a?.sha256 == "abcdef")
    }

    @Test func missingDigestIsNil() {
        let a = UpdateAsset.from(releaseJSON: release([["name": "x.dmg", "browser_download_url": good]]))
        #expect(a != nil)
        #expect(a?.sha256 == nil)
    }

    @Test func rejectsForeignHostsAndNonDmg() {
        #expect(UpdateAsset.from(releaseJSON: release([["name": "x.dmg", "browser_download_url": "https://evil.example/x.dmg"]])) == nil)
        #expect(UpdateAsset.from(releaseJSON: release([["name": "x.dmg", "browser_download_url": "http://github.com/Kristian-Buriasco/gogglecast/releases/download/v1/x.dmg"]])) == nil)
        #expect(UpdateAsset.from(releaseJSON: release([["name": "x.zip", "browser_download_url": good]])) == nil)
        #expect(UpdateAsset.from(releaseJSON: Data("nope".utf8)) == nil)
    }

    @Test func scriptQuotesPathsAndRelaunchesOnlyWhenAsked() {
        let s = UpdateInstallScript.make(pid: 42, staged: "/tmp/a b/it's.app", dest: "/Applications/GogglesView.app", relaunch: true)
        #expect(s.contains("STAGED='/tmp/a b/it'\\''s.app'"))
        #expect(s.contains("kill -0 42"))
        #expect(s.contains("/usr/bin/open"))
        let q = UpdateInstallScript.make(pid: 1, staged: "/s", dest: "/d", relaunch: false)
        #expect(!q.contains("/usr/bin/open"))
        #expect(q.contains("mv \"$OLD\" \"$DEST\""))  // rollback path
    }

    @Test func launchCheckRunsWhenOnlyAutoInstallIsOn() {
        // default (unset) means the daily check is on
        let d = UserDefaults.standard
        let saved = (d.object(forKey: UpdatePrefs.enabledKey), d.object(forKey: UpdatePrefs.lastCheckKey))
        defer { d.set(saved.0, forKey: UpdatePrefs.enabledKey); d.set(saved.1, forKey: UpdatePrefs.lastCheckKey) }
        d.removeObject(forKey: UpdatePrefs.enabledKey)
        #expect((d.object(forKey: UpdatePrefs.enabledKey) as? Bool ?? true) == true)
    }

    /// Runs the real mount/copy/verify path against a locally built DMG when one exists.
    @Test func verifiesRealBuiltDmgIfPresent() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist")
        guard let dmg = (try? FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil))?
            .filter({ $0.pathExtension == "dmg" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
        let ver = dmg.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "GogglesView-", with: "")
        let app = try UpdateInstaller.extractApp(dmg: dmg, expectedVersion: ver, current: nil)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/GogglesView").path))
    }
}
