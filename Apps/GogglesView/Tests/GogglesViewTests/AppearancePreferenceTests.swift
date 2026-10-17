import XCTest
@testable import GogglesView

final class AppearancePreferenceTests: XCTestCase {
    func testStoredDefaultsToSystemAndMapsAppearance() {
        let d = UserDefaults(suiteName: "AppearancePreferenceTests")!
        d.removePersistentDomain(forName: "AppearancePreferenceTests")
        XCTAssertEqual(AppearancePreference.stored(d), .system)
        XCTAssertNil(AppearancePreference.system.nsAppearance)

        d.set("dark", forKey: AppearancePreference.key)
        XCTAssertEqual(AppearancePreference.stored(d), .dark)
        XCTAssertEqual(AppearancePreference.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppearancePreference.light.nsAppearance?.name, .aqua)

        d.set("bogus", forKey: AppearancePreference.key)
        XCTAssertEqual(AppearancePreference.stored(d), .system)
    }
}
