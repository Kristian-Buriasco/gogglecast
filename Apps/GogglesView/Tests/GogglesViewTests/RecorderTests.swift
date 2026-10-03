import Testing
import Foundation
import CoreMedia
import GogglesXPC
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

@Suite struct OSDOverlayTests {
    @Test func linesRespectToggles() {
        let s = StreamStats(fps: 59, bitrateKbps: 12345, drops: 0,
                            cumulativeFrames: 1, cumulativeBytes: 1, cumulativeDrops: 3)
        #expect(OSDOverlay.lines(stats: s, fps: true, bitrate: true, resolution: false, drops: false)
                == ["59 fps", "12.3 Mbps"])
        #expect(OSDOverlay.lines(stats: s, fps: false, bitrate: false, resolution: false, drops: true)
                == ["3 dropped"])
        #expect(OSDOverlay.lines(stats: s, fps: false, bitrate: false, resolution: false, drops: false).isEmpty)
    }
}
