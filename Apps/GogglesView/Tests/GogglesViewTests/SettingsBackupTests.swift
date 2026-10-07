import Foundation
import Testing
@testable import GogglesView

@Suite struct SettingsBackupTests {
    private func suite() -> UserDefaults {
        let name = "SettingsBackupTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func roundTrip() throws {
        let a = suite()
        a.set(true, forKey: ReplayPrefs.enabledKey)
        a.set(60, forKey: ReplayPrefs.secondsKey)
        a.set(1.5, forKey: FramingPrefs.zoomKey)
        a.set("r9x16", forKey: OutputFramingPrefs.aspectKey)
        let data = try SettingsBackup.encode(defaults: a, appVersion: "9.9")
        let b = suite()
        let plan = try SettingsBackup.plan(from: data, defaults: b)
        #expect(plan.count == 4)
        SettingsBackup.apply(plan, defaults: b)
        #expect(b.bool(forKey: ReplayPrefs.enabledKey))
        #expect(b.integer(forKey: ReplayPrefs.secondsKey) == 60)
        #expect(b.double(forKey: FramingPrefs.zoomKey) == 1.5)
        #expect(b.string(forKey: OutputFramingPrefs.aspectKey) == "r9x16")
        #expect(try SettingsBackup.plan(from: data, defaults: b).count == 0)
    }

    @Test func secretsAreNeverExported() throws {
        let d = suite()
        let secrets = [RTMPPrefs.streamKeyKey, RTMPPrefs.urlKey, SRTPrefs.passphraseKey, WebViewerPrefs.tokenKey,
                       UpdatePrefs.tokenKey, RecordingPrefs.folderKey, ProfileStore.storageKey, BurnInPrefs.logoFileKey,
                       NDIPrefs.libraryPathKey, SRTPrefs.libraryPathKey, SRTPrefs.hostKey, EventHookConfig.scriptKey(.streamLost),
                       EventHookConfig.webhookKey(.streamLost), "NSWindow Frame GogglesMiniWindow",
                       AutomationPrefs.urlEnabledKey, WebViewerPrefs.enabledKey, UpdatePrefs2.autoInstallKey]
        for k in secrets { d.set("secret-value", forKey: k) }
        let text = String(decoding: try SettingsBackup.encode(defaults: d, appVersion: "1"), as: UTF8.self)
        #expect(!text.contains("secret-value"))
        for k in secrets { #expect(!SettingsBackup.allowedKeys.contains(k), "\(k)") }
        for k in SettingsBackup.allowedKeys {
            let l = k.lowercased()
            for bad in ["secret", "passphrase", "token", "streamkey", "webhook", "script", "serial", "folder", "path", "frame"] {
                #expect(!l.contains(bad), "\(k)")
            }
        }
    }

    @Test func importValidatesClampsAndIgnores() throws {
        let json = """
        {"format":1,"app":"x","settings":{
          "replaySeconds": 9999, "replayEnabled": "yes", "framingZoom": 50.0,
          "viewRotation": 45, "rtmpStreamKey": "abc", "unknownThing": 1, "osdEnabled": true}}
        """
        let d = suite()
        let plan = try SettingsBackup.plan(from: Data(json.utf8), defaults: d)
        #expect(plan.values[ReplayPrefs.secondsKey] as? Int == ReplayPrefs.secondsRange.upperBound)
        #expect(plan.values[FramingPrefs.zoomKey] as? Double == 4)
        #expect(Set(plan.rejected) == [ReplayPrefs.enabledKey, OrientationPrefs.rotationKey])
        #expect(Set(plan.ignored) == ["rtmpStreamKey", "unknownThing"])
        SettingsBackup.apply(plan, defaults: d)
        #expect(d.string(forKey: RTMPPrefs.streamKeyKey) == nil)
        #expect(d.bool(forKey: OSDPrefs.enabledKey))
    }

    @Test func rejectsBadFiles() {
        #expect(throws: SettingsBackup.ImportError.notSettingsFile) { try SettingsBackup.plan(from: Data("[]".utf8), defaults: suite()) }
        #expect(throws: SettingsBackup.ImportError.newerFormat(99)) {
            try SettingsBackup.plan(from: Data(#"{"format":99,"settings":{}}"#.utf8), defaults: suite())
        }
    }

    @Test func summaryText() {
        var p = SettingsBackup.Plan()
        p.changed = ["a"]
        #expect(SettingsBackup.summary(p, applied: false) == "1 setting will change.")
        p.changed = ["a", "b"]
        p.rejected = ["c"]
        #expect(SettingsBackup.summary(p, applied: true) == "Applied 2 settings. Skipped 1 with invalid values.")
    }
}
