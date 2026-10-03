import XCTest
import Carbon.HIToolbox
@testable import GogglesView

final class QoLFeatureTests: XCTestCase {
    func testVersionComparator() {
        XCTAssertTrue(VersionComparator.isNewer(remote: "v0.2", than: "0.1"))
        XCTAssertTrue(VersionComparator.isNewer(remote: "0.10", than: "0.9"))
        XCTAssertTrue(VersionComparator.isNewer(remote: "1.0.1", than: "1.0"))
        XCTAssertFalse(VersionComparator.isNewer(remote: "v1.0", than: "1.0.0"))
        XCTAssertFalse(VersionComparator.isNewer(remote: "0.1", than: "0.2"))
        XCTAssertFalse(VersionComparator.isNewer(remote: "garbage", than: "0.2"))
        XCTAssertTrue(VersionComparator.isNewer(remote: "v0.3-beta", than: "0.2"))
    }

    func testInterpretResponse() {
        let json = Data(#"{"tag_name":"v0.3","html_url":"https://github.com/x/y/releases/tag/v0.3"}"#.utf8)
        guard case .available(let tag, _) = UpdateChecker.interpret(status: 200, data: json, current: "0.2") else { return XCTFail() }
        XCTAssertEqual(tag, "v0.3")
        XCTAssertEqual(UpdateChecker.interpret(status: 200, data: json, current: "0.3"), .upToDate("v0.3"))
        XCTAssertEqual(UpdateChecker.interpret(status: 404, data: Data(), current: "0.2"), .failed)
        XCTAssertEqual(UpdateChecker.interpret(status: 200, data: Data("x".utf8), current: "0.2"), .failed)
    }

    func testDisplayString() {
        XCTAssertEqual(HotkeyCombo.displayString(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: GlobalHotkeyAction.defaultModifiers), "⌃⌥⌘R")
        XCTAssertEqual(HotkeyCombo.displayString(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(shiftKey | cmdKey)), "⇧⌘F5")
    }

    func testConflictAndPersistence() {
        let a = GlobalHotkeyAction.screenshot
        let all = Dictionary(uniqueKeysWithValues: GlobalHotkeyAction.allCases.map { ($0, $0.defaultCombo) })
        XCTAssertEqual(GlobalHotkeyBindings.conflict(for: a, candidate: GlobalHotkeyAction.saveReplay.defaultCombo, assignments: all), .saveReplay)
        XCTAssertNil(GlobalHotkeyBindings.conflict(for: a, candidate: a.defaultCombo, assignments: all))
        let d = UserDefaults(suiteName: "qol-test-\(UUID())")!
        XCTAssertEqual(GlobalHotkeyBindings.combo(for: a, defaults: d), a.defaultCombo)
        let c = HotkeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey))
        GlobalHotkeyBindings.set(c, for: a, defaults: d)
        XCTAssertEqual(GlobalHotkeyBindings.combo(for: a, defaults: d), c)
        GlobalHotkeyBindings.reset(a, defaults: d)
        XCTAssertEqual(GlobalHotkeyBindings.combo(for: a, defaults: d), a.defaultCombo)
    }

    func testPresets() {
        let d = UserDefaults(suiteName: "qol-test-\(UUID())")!
        SettingsPreset.recording.apply(to: d)
        XCTAssertTrue(d.bool(forKey: RecordingPrefs.autoStartKey))
        XCTAssertEqual(d.integer(forKey: ReplayPrefs.secondsKey), 60)
        d.set(2.0, forKey: FramingPrefs.zoomKey)
        SettingsPreset.streaming.apply(to: d)
        XCTAssertTrue(d.bool(forKey: NetStreamPrefs.autoStartKey))
        XCTAssertFalse(d.bool(forKey: RecordingPrefs.autoStartKey))
        XCTAssertNil(d.object(forKey: ReplayPrefs.secondsKey))
        XCTAssertNil(d.object(forKey: FramingPrefs.zoomKey))
        SettingsPreset.resetAll(in: d)
        XCTAssertNil(d.object(forKey: NetStreamPrefs.autoStartKey))
        XCTAssertEqual(Set(SettingsPreset.allCases.map { Set($0.values.keys) }).count, 1)
    }

    func testWindowFrameValidation() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertNil(WindowMemory.onScreenFrame(CGRect(x: 3000, y: 100, width: 800, height: 450), visibleFrames: screens))
        let f = WindowMemory.onScreenFrame(CGRect(x: 1200, y: 700, width: 800, height: 450), visibleFrames: screens)
        XCTAssertEqual(f, CGRect(x: 640, y: 450, width: 800, height: 450))
        XCTAssertEqual(WindowMemory.onScreenFrame(CGRect(x: 0, y: 0, width: 5000, height: 450), visibleFrames: screens)?.width, 1440)
    }
}
