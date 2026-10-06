import XCTest
@testable import GogglesView

final class RaceModeTests: XCTestCase {
    private let everything = UserPreviewSettings(stabilize: true, previewLUT: true, colorAdjust: true,
                                                 osd: true, grid: true, miniWindow: true)

    func testPrefsDefaultOffAndRoundTrip() {
        let d = UserDefaults(suiteName: "race-test-\(UUID())")!
        XCTAssertEqual(RaceModePrefs.key, "raceMode")
        XCTAssertFalse(RaceModePrefs.isEnabled(d))
        RaceModePrefs.set(true, defaults: d)
        XCTAssertTrue(RaceModePrefs.isEnabled(d))
        RaceModePrefs.set(false, defaults: d)
        XCTAssertFalse(RaceModePrefs.isEnabled(d))
    }

    func testOffKeepsUserSettings() {
        let c = PreviewPipelineConfig.resolve(raceMode: false, user: everything)
        XCTAssertTrue(c.stabilizer && c.previewLUT && c.colorFilters && c.osdOverlay && c.gridOverlay && c.miniWindow)
        XCTAssertFalse(c.lowLatencyDecoder)
        XCTAssertFalse(c.badge)
    }

    func testOnDisablesEverythingOptional() {
        let c = PreviewPipelineConfig.resolve(raceMode: true, user: everything)
        XCTAssertFalse(c.stabilizer)
        XCTAssertFalse(c.previewLUT)
        XCTAssertFalse(c.colorFilters)
        XCTAssertFalse(c.osdOverlay)
        XCTAssertFalse(c.gridOverlay)
        XCTAssertFalse(c.miniWindow)
        XCTAssertTrue(c.lowLatencyDecoder)
        XCTAssertTrue(c.badge)
    }

    func testFeaturesTheUserNeverEnabledStayOff() {
        let c = PreviewPipelineConfig.resolve(raceMode: false, user: UserPreviewSettings())
        XCTAssertFalse(c.stabilizer || c.previewLUT || c.colorFilters || c.osdOverlay || c.gridOverlay || c.miniWindow)
    }

    func testLiveReadersFollowDefaults() {
        let key = RaceModePrefs.key
        let old = UserDefaults.standard.object(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        RaceModePrefs.set(true)
        XCTAssertNil(FramingPrefs.colorFilters())
        XCTAssertTrue(PreviewPipelineConfig.current.badge)
        RaceModePrefs.set(false)
        XCTAssertFalse(PreviewPipelineConfig.current.badge)
    }

    func testApplyRaceModeWithoutDecoderIsSafe() {
        DecodeSession().applyRaceMode(true)
    }
}
