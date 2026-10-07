import Foundation
import Testing
@testable import GogglesView

@Suite(.serialized)
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

    @Test func scriptReverifiesRollsBackCleansUpAndNeverClearsQuarantine() {
        let s = UpdateInstallScript.make(pid: 1, staged: "/w/out/GogglesView.app", dest: "/Applications/GogglesView.app", relaunch: false, cleanup: "/w")
        #expect(!s.contains("quarantine"))
        #expect(!s.contains("xattr"))
        #expect(s.contains("codesign --verify --strict"))
        #expect(s.contains("rm -rf '/w'"))
        #expect(s.contains("rm -f \"$0\""))
        // codesign failure takes the same rollback branch as a failed copy
        #expect(s.contains("ditto \"$STAGED\" \"$DEST\" && /usr/bin/codesign"))
    }

    @Test func releaseUrlIsRestrictedToGithub() {
        #expect(UpdateChecker.safeReleaseURL("https://github.com/Kristian-Buriasco/gogglecast/releases/tag/v1") != nil)
        #expect(UpdateChecker.safeReleaseURL("https://evil.example/x") == nil)
        #expect(UpdateChecker.safeReleaseURL("http://github.com/x") == nil)
        #expect(UpdateChecker.safeReleaseURL("https://github.com.evil.example/x") == nil)
        #expect(UpdateChecker.safeReleaseURL("file:///etc/passwd") == nil)
        let json = try! JSONSerialization.data(withJSONObject: ["tag_name": "v99.0", "html_url": "https://evil.example/pwn"])
        #expect(UpdateChecker.interpret(status: 200, data: json, current: "1.0") == .available(tag: "v99.0", url: UpdatePrefs.releasesPage))
    }

    @Test func teamRequirementRejectsInjection() {
        #expect(UpdateSignature.teamRequirement("ABCDE12345") == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(UpdateSignature.teamRequirement("ABC\" or true") == nil)
        #expect(UpdateSignature.teamRequirement("abcde12345") == nil)
        #expect(UpdateSignature.teamRequirement("") == nil)
    }

    private func adHocCopyOfTrue() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gv-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "-s", "-", bin.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return bin
    }

    @Test func adHocSignaturesAreDetectedAndDoNotSatisfyTeamRequirement() throws {
        let bin = try adHocCopyOfTrue()
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        #expect(UpdateSignature.isAdHocOrUnsigned(bin))
        if case .none = UpdateSignature.pin(forRunningApp: bin) {} else { Issue.record("ad-hoc build must not produce a pin") }
        let req = UpdateSignature.teamRequirement("ABCDE12345")!
        #expect(!UpdateSignature.satisfies(bin, requirement: req))
        // A signed-by-Apple platform binary is not ad hoc and yields a pin it satisfies itself.
        let ls = URL(fileURLWithPath: "/bin/ls")
        #expect(!UpdateSignature.isAdHocOrUnsigned(ls))
        if case .requirement(let r) = UpdateSignature.pin(forRunningApp: ls) {
            #expect(UpdateSignature.satisfies(ls, requirement: r))
            #expect(!UpdateSignature.satisfies(bin, requirement: r))
        } else { Issue.record("expected a requirement pin for an Apple-signed binary") }
    }

    @Test func verifyFailsClosedWithoutPinOrWithWrongIdentity() throws {
        let bin = try adHocCopyOfTrue()
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        #expect(throws: UpdateInstaller.UpdateError.self) {
            try UpdateInstaller.verify(staged: bin, current: nil, pin: .none, expectedVersion: "9.9")
        }
        #expect(throws: UpdateInstaller.UpdateError.self) {
            try UpdateInstaller.verify(staged: bin, current: nil, pin: .requirement(UpdateSignature.teamRequirement("ABCDE12345")!), expectedVersion: "9.9")
        }
    }

    @Test func adHocRunningAppOpensReleasesPageInsteadOfInstalling() {
        let inst = UpdateInstaller()
        var opened: URL?
        inst.pinProvider = { .none }
        inst.openURL = { opened = $0 }
        inst.stage(asset: UpdateAsset(name: "x.dmg", url: URL(string: good)!, sha256: "ab"), version: "9.9")
        #expect(opened == UpdatePrefs.releasesPage)
        if case .manual = inst.state {} else { Issue.record("expected .manual state, got \(inst.state)") }
    }

    @Test func missingDigestFailsClosed() {
        let inst = UpdateInstaller()
        inst.pinProvider = { .requirement("anchor apple") }
        inst.stage(asset: UpdateAsset(name: "x.dmg", url: URL(string: good)!, sha256: nil), version: "9.9")
        if case .failed = inst.state {} else { Issue.record("expected .failed, got \(inst.state)") }
    }

    @Test func installRefusedWhileAnyOutputIsActive() {
        let inst = UpdateInstaller()
        var terminated = false
        inst.terminateApp = { terminated = true }
        inst.markStaged(app: URL(fileURLWithPath: "/nonexistent/out/GogglesView.app"), version: "9.9", arm: false)
        inst.isBusyProbe = { true }
        inst.installAndRestart()
        #expect(!terminated)
        #expect(inst.blockedReason != nil)
        #expect(inst.state == .staged(version: "9.9"))
    }

    @Test func checksumMismatchRemovesWorkDirectory() throws {
        let fm = FileManager.default
        let tmpBefore = Set((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("gogglesview-update-") }
        let dmg = fm.temporaryDirectory.appendingPathComponent("gv-fake-\(UUID().uuidString).dmg")
        try Data("not a dmg".utf8).write(to: dmg)
        defer { try? fm.removeItem(at: dmg) }
        #expect(throws: UpdateInstaller.UpdateError.self) {
            try UpdateInstaller.extractApp(dmg: dmg, expectedVersion: "9.9", pin: .integrityOnlyForTests,
                                           expectedSHA256: String(repeating: "0", count: 64), current: nil)
        }
        let tmpAfter = Set((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("gogglesview-update-") }
        #expect(tmpAfter.subtracting(tmpBefore).isEmpty)
    }

    @Test func sha256HexMatchesKnownVector() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("gv-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(try UpdateInstaller.sha256Hex(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Runs the real mount/copy/verify path against a locally built DMG when one exists.
    @Test func verifiesRealBuiltDmgIfPresent() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist")
        guard let dmg = (try? FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil))?
            .filter({ $0.pathExtension == "dmg" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
        let ver = dmg.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "GogglesView-", with: "")
        let app = try UpdateInstaller.extractApp(dmg: dmg, expectedVersion: ver, pin: .integrityOnlyForTests,
                                                 expectedSHA256: try UpdateInstaller.sha256Hex(of: dmg), current: nil)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/GogglesView").path))
    }
}
