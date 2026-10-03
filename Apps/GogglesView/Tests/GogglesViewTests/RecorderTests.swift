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
        #expect(OSDOverlay.lines(stats: s, resolution: "1920x1080", fps: true, bitrate: true, showResolution: false, drops: false)
                == ["59 fps", "12.3 Mbps"])
        #expect(OSDOverlay.lines(stats: s, resolution: "1920x1080", fps: false, bitrate: false, showResolution: true, drops: false)
                == ["1920x1080"])
        #expect(OSDOverlay.lines(stats: s, resolution: nil, fps: false, bitrate: false, showResolution: false, drops: true)
                == ["3 dropped"])
        #expect(OSDOverlay.lines(stats: s, resolution: nil, fps: false, bitrate: false, showResolution: false, drops: false).isEmpty)
    }
}

@Suite struct ScreenshotTests {
    @Test func fileNameFormat() {
        let d = Date(timeIntervalSince1970: 0)
        #expect(Screenshot.fileName(for: d, timeZone: TimeZone(identifier: "UTC")!) == "GogglesView-1970-01-01-00-00-00.png")
    }
}

@Suite struct LatencyTests {
    @Test func tickConversion() {
        // timebase 125/3 (Apple Silicon): 24 ticks = 1000 ns
        #expect(abs(DecodeSession.milliseconds(fromTicks: 24_000_000, numer: 125, denom: 3) - 1000) < 0.001)
    }
    @Test func overlayShowsLatency() {
        let s = StreamStats(fps: 60, bitrateKbps: 1, drops: 0, cumulativeFrames: 1, cumulativeBytes: 1, cumulativeDrops: 0)
        #expect(OSDOverlay.lines(stats: s, resolution: nil, fps: false, bitrate: false, showResolution: false,
                                 drops: false, latencyMs: 12.4, showLatency: true) == ["12 ms"])
    }
}

@Suite struct OrientationTests {
    @Test func transforms() {
        let id = OrientationPrefs.transform(rotation: 0, flipH: false, flipV: false)
        #expect(id.isIdentity)
        let r180 = OrientationPrefs.transform(rotation: 180, flipH: false, flipV: false)
        #expect(abs(r180.a + 1) < 1e-9 && abs(r180.d + 1) < 1e-9)
        let fh = OrientationPrefs.transform(rotation: 0, flipH: true, flipV: false)
        #expect(fh.a == -1 && fh.d == 1)
        #expect(OrientationPrefs.swapsAxes(90) && OrientationPrefs.swapsAxes(270) && !OrientationPrefs.swapsAxes(180))
    }
}
