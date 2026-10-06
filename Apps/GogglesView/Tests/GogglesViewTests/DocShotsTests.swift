import XCTest
@testable import GogglesView

final class DocShotsTests: XCTestCase {
    func testDevShotFlagsNeedTheEnvironmentOptIn() {
        XCTAssertFalse(DocShots.isEnabled(environment: [:]))
        XCTAssertFalse(DocShots.isEnabled(environment: ["GOGGLESVIEW_DEV_SHOTS": "0"]))
        XCTAssertFalse(DocShots.isEnabled(environment: ["GOGGLESVIEW_DEV_SHOTS": "true"]))
        XCTAssertTrue(DocShots.isEnabled(environment: ["GOGGLESVIEW_DEV_SHOTS": "1"]))
    }

    func testOverridesAreVisibleButNeverPersisted() {
        let name = "DocShotsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set("/Users/me/Movies", forKey: "recordingFolder")

        DocShots.overridePrefs(["recordingFolder": "/tmp/doc-shot-clips", "settingsTab": "Display"], defaults: d)
        XCTAssertEqual(d.string(forKey: "recordingFolder"), "/tmp/doc-shot-clips")
        XCTAssertEqual(d.string(forKey: "settingsTab"), "Display")

        // The persistent domain still holds the user's real value and never saw the override.
        let persistent = d.persistentDomain(forName: name) ?? [:]
        XCTAssertEqual(persistent["recordingFolder"] as? String, "/Users/me/Movies")
        XCTAssertNil(persistent["settingsTab"])
    }
}
