import XCTest
@testable import GogglesView

final class OverlayHintTests: XCTestCase {
    func testShowsOnlyWhenNotSuppressedAndNotCropped() {
        XCTAssertTrue(OverlayHint.shouldShow(suppressed: false, cropActive: false))
        XCTAssertFalse(OverlayHint.shouldShow(suppressed: true, cropActive: false))
        XCTAssertFalse(OverlayHint.shouldShow(suppressed: false, cropActive: true))
    }

    func testTextDiffersPerKindAndNamesTheRightSetting() {
        let out = OverlayHint.text(for: .output), cap = OverlayHint.text(for: .captureWindow)
        XCTAssertTrue(out.body.contains("Output framing"))
        XCTAssertTrue(cap.body.contains("Window Capture"))
        XCTAssertNotEqual(out.title, cap.title)
        XCTAssertFalse((out.title + out.body + cap.title + cap.body).contains("\u{2014}"), "no em dashes")
    }
}
