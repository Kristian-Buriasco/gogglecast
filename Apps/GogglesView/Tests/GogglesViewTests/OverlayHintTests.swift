import XCTest
@testable import GogglesView

final class OverlayHintTests: XCTestCase {
    func testShowsOnlyWhenNotSuppressedAndNotCropped() {
        XCTAssertTrue(OverlayHint.shouldShow(suppressed: false, cropActive: false))
        XCTAssertFalse(OverlayHint.shouldShow(suppressed: true, cropActive: false))
        XCTAssertFalse(OverlayHint.shouldShow(suppressed: false, cropActive: true))
    }

    func testShownOncePerLaunch() {
        XCTAssertFalse(OverlayHint.shouldShow(suppressed: false, cropActive: false, shownThisLaunch: true))
        XCTAssertTrue(OverlayHint.shouldShow(suppressed: false, cropActive: false, shownThisLaunch: false))
        // Second noteStarted in the same launch is a no-op (flag set synchronously on the first).
        OverlayHint.resetLaunchStateForTests()
        let key = OverlayHint.suppressKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key); OverlayHint.resetLaunchStateForTests() }
        UserDefaults.standard.set(true, forKey: key) // suppressed: never shows, never flags
        OverlayHint.noteStarted(.captureWindow)
        UserDefaults.standard.set(false, forKey: key)
    }

    func testTextDiffersPerKindAndNamesTheRightSetting() {
        let out = OverlayHint.text(for: .output), cap = OverlayHint.text(for: .captureWindow)
        XCTAssertTrue(out.body.contains("Output framing"))
        XCTAssertTrue(cap.body.contains("Window Capture"))
        XCTAssertNotEqual(out.title, cap.title)
        XCTAssertTrue(out.body.contains("70%") && out.body.contains("1.4x"), "output tip about display scale")
        XCTAssertTrue(cap.body.contains("70%") && cap.body.contains("1.4x"), "capture tip about display scale")
        XCTAssertFalse((out.title + out.body + cap.title + cap.body).contains("\u{2014}"), "no em dashes")
    }
}
