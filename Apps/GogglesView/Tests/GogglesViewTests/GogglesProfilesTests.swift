import Testing
import Foundation
@testable import GogglesView

struct GogglesProfilesTests {
    private func suite(_ n: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "profiles-test-\(n)-\(UUID().uuidString)")!
        return d
    }

    @Test func snapshotApplyRoundTrip() throws {
        let a = suite("a"), b = suite("b")
        a.set(true, forKey: OSDPrefs.enabledKey)
        a.set(60, forKey: ReplayPrefs.secondsKey)
        a.set(1.5, forKey: FramingPrefs.zoomKey)
        a.set(90, forKey: OrientationPrefs.rotationKey)
        a.set("mov", forKey: RecordingPrefs.containerKey)
        let snap = ProfileStore.snapshot(from: a)
        #expect(snap[OSDPrefs.enabledKey] == .bool(true))
        #expect(snap[ReplayPrefs.secondsKey] == .int(60))
        #expect(snap[FramingPrefs.zoomKey] == .double(1.5))
        #expect(snap[OrientationPrefs.rotationKey] == .int(90))

        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode([String: ProfileValue].self, from: data)
        #expect(back == snap)

        b.set(30, forKey: ReplayPrefs.secondsKey)
        b.set(true, forKey: FramingPrefs.gridKey) // not in snapshot -> removed
        ProfileStore.apply(back, to: b)
        #expect(b.integer(forKey: ReplayPrefs.secondsKey) == 60)
        #expect(b.bool(forKey: OSDPrefs.enabledKey))
        #expect(b.object(forKey: FramingPrefs.gridKey) == nil)
        #expect(b.string(forKey: RecordingPrefs.containerKey) == "mov")
    }

    @Test func storeAutoApplyAndNickname() {
        let meta = suite("meta"), settings = suite("settings")
        let s = ProfileStore(store: meta, settings: settings)
        settings.set(true, forKey: OSDPrefs.enabledKey)
        s.setNickname("Race", for: "SN1")
        s.saveCurrentSettings(for: "SN1")
        settings.set(false, forKey: OSDPrefs.enabledKey)

        #expect(!s.applyIfEnabled(serial: "SN1"))      // auto-apply off
        s.setAutoApply(true, for: "SN1")
        #expect(!s.applyIfEnabled(serial: "other"))
        #expect(!s.applyIfEnabled(serial: nil))
        #expect(s.applyIfEnabled(serial: "SN1"))
        #expect(settings.bool(forKey: OSDPrefs.enabledKey))
        #expect(s.nickname(for: "SN1") == "Race")
        #expect(s.nickname(for: "SN2") == nil)
    }

    @Test func displayName() {
        #expect(profileDisplayName(nickname: "Race", serial: "X") == "Race (X)")
        #expect(profileDisplayName(nickname: "", serial: "X") == nil)
        #expect(profileDisplayName(nickname: nil, serial: "X") == nil)
    }
}

struct AccessibilityLabelsTests {
    @Test func pickerRowSummary() {
        #expect(AccessibilityLabels.pickerRow(product: nil, serial: "S1", nickname: "Race", usbID: "2CA3:0020", bus: 20, address: 3)
                == "Race, DJI Goggles 3, serial S1, USB 2CA3:0020, bus 20 address 3")
        #expect(AccessibilityLabels.pickerRow(product: "G", serial: nil, nickname: nil, usbID: "A:B", bus: 1, address: 2)
                == "G, serial unknown, USB A:B, bus 1 address 2")
    }
    @Test func recordState() {
        #expect(AccessibilityLabels.recordState(isRecording: false, elapsed: nil) == "Not recording")
        #expect(AccessibilityLabels.recordState(isRecording: true, elapsed: "00:05") == "Recording 00:05")
    }
}
