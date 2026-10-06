import XCTest
@testable import GogglesView

final class AccessibilityCoverageTests: XCTestCase {
    func testQuantityIncludesSpokenUnit() {
        XCTAssertEqual(AccessibilityLabels.quantity(60, unit: "percent"), "60 percent")
        XCTAssertEqual(AccessibilityLabels.quantity(3, unit: "seconds"), "3 seconds")
    }

    func testOnOff() {
        XCTAssertEqual(AccessibilityLabels.onOff(true), "On")
        XCTAssertEqual(AccessibilityLabels.onOff(false), "Off")
    }

    func testCheckStatusIsNeverColourOnly() {
        XCTAssertEqual(AccessibilityLabels.checkStatus(pass: true, fail: false), "Passed")
        XCTAssertEqual(AccessibilityLabels.checkStatus(pass: false, fail: true), "Failed")
        XCTAssertEqual(AccessibilityLabels.checkStatus(pass: false, fail: false), "Not checked")
    }

    func testStreamState() {
        XCTAssertEqual(AccessibilityLabels.streamState(isStreaming: false, connected: false, error: nil), "Stopped")
        XCTAssertEqual(AccessibilityLabels.streamState(isStreaming: true, connected: false, error: nil), "Waiting for peer")
        XCTAssertEqual(AccessibilityLabels.streamState(isStreaming: true, connected: true, error: nil), "Connected")
        XCTAssertEqual(AccessibilityLabels.streamState(isStreaming: true, connected: true, error: "Refused"), "Refused")
        XCTAssertEqual(AccessibilityLabels.streamState(isStreaming: false, connected: false, error: ""), "Stopped")
    }
}
