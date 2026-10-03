import Testing
import Foundation
import CoreMedia
@testable import GogglesView

struct RecorderTests {
    @Test func fileNameFormat() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        #expect(Recorder.fileName(for: date, timeZone: utc) == "GogglesView-2023-11-14-22-13-20.mov")
    }

    @Test func defaultDirectoryIsMoviesGogglesView() {
        #expect(Recorder.defaultDirectory.path.hasSuffix("/Movies/GogglesView"))
    }

    @Test func normalizationStartsAtZero() {
        let start = CMTime(value: 5000, timescale: 1000)
        let t = CMTime(value: 5500, timescale: 1000)
        #expect(CMTimeGetSeconds(Recorder.normalized(start, relativeTo: start)) == 0)
        #expect(CMTimeGetSeconds(Recorder.normalized(t, relativeTo: start)) == 0.5)
    }
}
