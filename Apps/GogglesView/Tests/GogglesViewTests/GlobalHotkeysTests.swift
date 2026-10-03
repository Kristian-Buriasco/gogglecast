import XCTest
import Carbon.HIToolbox
@testable import GogglesView

final class GlobalHotkeysTests: XCTestCase {
    func testDefaultCombos() {
        let all = UInt32(controlKey | optionKey | cmdKey)
        XCTAssertEqual(GlobalHotkeyAction.toggleRecording.combo, HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: all, display: "⌃⌥⌘R"))
        XCTAssertEqual(GlobalHotkeyAction.screenshot.combo.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(GlobalHotkeyAction.saveReplay.combo.keyCode, UInt32(kVK_ANSI_P))
    }
    func testCombosUniqueAndNotificationsMapped() {
        let codes = Set(GlobalHotkeyAction.allCases.map { $0.combo.keyCode })
        XCTAssertEqual(codes.count, 3)
        XCTAssertEqual(GlobalHotkeyAction.saveReplay.notification, .gogglesSaveReplay)
    }
    func testDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: GlobalHotkeyPrefs.enabledKey)
        XCTAssertFalse(GlobalHotkeyPrefs.enabled)
    }
}
