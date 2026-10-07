import Testing
@testable import GogglesView

@Suite struct ReplayMessageTests {
    @Test func offWinsOverEncoder() {
        #expect(ReplayPrefs.blockedMessage(enabled: false, reencode: false, outputActive: false) == "Instant replay is off. Turn it on in Settings > Recording.")
    }
    @Test func needsEncoder() {
        #expect(ReplayPrefs.blockedMessage(enabled: true, reencode: false, outputActive: false) == ReplayPrefs.unavailableMessage)
    }
    @Test func readyHasNoMessage() {
        #expect(ReplayPrefs.blockedMessage(enabled: true, reencode: true, outputActive: false) == nil)
        #expect(ReplayPrefs.blockedMessage(enabled: true, reencode: false, outputActive: true) == nil)
    }
}
