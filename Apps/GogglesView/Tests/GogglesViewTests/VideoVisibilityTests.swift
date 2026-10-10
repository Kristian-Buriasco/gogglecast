import Testing
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
