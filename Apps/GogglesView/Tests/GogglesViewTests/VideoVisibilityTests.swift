import Testing
import Foundation
@testable import GogglesView

@Suite struct VideoVisibilityTests {
    @Test func lastPictureStaysWhenSignalDrops() {
        #expect(VideoVisibility.opacity(kind: .live, hadPicture: true) == 1)
        #expect(VideoVisibility.opacity(kind: .stalled, hadPicture: true) == 0.4)
        #expect(VideoVisibility.opacity(kind: .handshaking, hadPicture: true) == 0.4)
        #expect(VideoVisibility.opacity(kind: .waitingForKeyframe, hadPicture: true) == 0.4)
    }

    @Test func nothingToShowBeforeTheFirstPicture() {
        #expect(VideoVisibility.opacity(kind: .handshaking, hadPicture: false) == 0)
        #expect(VideoVisibility.opacity(kind: .waitingForKeyframe, hadPicture: false) == 0)
        #expect(VideoVisibility.opacity(kind: .noDevice, hadPicture: true) == 0)
        #expect(VideoVisibility.opacity(kind: .claiming, hadPicture: true) == 0)
    }
}

@Suite struct SecretStoreTestIsolationTests {
    @Test func testsNeverUseTheRealKeychain() {
        #expect(SecretStore.runningUnderTests)
        #expect(!(SecretStore.backend is SecretStore.KeychainBackend), "a test touching the login keychain prompts for its password")
    }
}

@Suite struct BackToListTests {
    @Test func offeredOnlyAfterTheGogglesWereMissingForAWhile() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!BackToList.shouldOffer(kind: .noDevice, since: t0, now: t0.addingTimeInterval(3)))
        #expect(BackToList.shouldOffer(kind: .noDevice, since: t0, now: t0.addingTimeInterval(9)))
        #expect(BackToList.shouldOffer(kind: .claimFailed, since: t0, now: t0.addingTimeInterval(30)))
    }

    @Test func neverOfferedWhileConnectingOrLive() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for kind in [GogglesUIStateKind.live, .claiming, .handshaking, .waitingForKeyframe, .stalled] {
            #expect(!BackToList.shouldOffer(kind: kind, since: t0, now: t0.addingTimeInterval(60)))
        }
        #expect(!BackToList.shouldOffer(kind: .noDevice, since: nil, now: t0))
    }

    @Test func clockStartsOnTroubleAndResetsWhenTheGogglesComeBack() {
        var clock = TroubleClock()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        clock.note(kind: .noDevice, at: t0)
        clock.note(kind: .noDevice, at: t0.addingTimeInterval(5))
        #expect(clock.since == t0, "a repeated callback must not restart the clock")
        clock.note(kind: .claiming, at: t0.addingTimeInterval(6))
        #expect(clock.since == t0, "claiming is still part of the same search")
        clock.note(kind: .live, at: t0.addingTimeInterval(7))
        #expect(clock.since == nil)
    }
}
