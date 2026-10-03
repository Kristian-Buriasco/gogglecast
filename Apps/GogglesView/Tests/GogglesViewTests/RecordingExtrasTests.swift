import Testing
import Foundation
@testable import GogglesView

struct RecordingExtrasTests {
    @Test func limitsAndShouldSplit() {
        let off = RecordingExtras.limits(splitMinutes: 0, splitMegabytes: 0, loopKeepMinutes: 0)
        #expect(!RecordingExtras.shouldSplit(elapsed: 1e6, bytes: Int64.max, limits: off))
        let l = RecordingExtras.limits(splitMinutes: 5, splitMegabytes: 100, loopKeepMinutes: 0)
        #expect(!RecordingExtras.shouldSplit(elapsed: 299, bytes: 99_000_000, limits: l))
        #expect(RecordingExtras.shouldSplit(elapsed: 300, bytes: 0, limits: l))
        #expect(RecordingExtras.shouldSplit(elapsed: 1, bytes: 100_000_000, limits: l))
        #expect(RecordingExtras.limits(splitMinutes: 500, splitMegabytes: 0, loopKeepMinutes: 0).maxSeconds == 7200)
    }

    @Test func loopOverridesSplitLength() {
        #expect(RecordingExtras.limits(splitMinutes: 30, splitMegabytes: 0, loopKeepMinutes: 12).maxSeconds == 120)
        #expect(RecordingExtras.limits(splitMinutes: 0, splitMegabytes: 0, loopKeepMinutes: 3).maxSeconds == 60)
        #expect(RecordingExtras.limits(splitMinutes: 0, splitMegabytes: 0, loopKeepMinutes: 3).loopKeepSeconds == 180)
    }

    @Test func partNames() {
        let base = URL(fileURLWithPath: "/tmp/GV-2024-01-01-10-00-00.mp4")
        #expect(RecordingExtras.partURL(base: base, part: 1) == base)
        #expect(RecordingExtras.partURL(base: base, part: 2).lastPathComponent == "GV-2024-01-01-10-00-00-part2.mp4")
        #expect(RecordingExtras.partURL(base: base, part: 10).lastPathComponent == "GV-2024-01-01-10-00-00-part10.mp4")
    }

    @Test func retention() {
        #expect(RecordingExtras.segmentsToDelete(durations: [60, 60, 60], keepSeconds: 180) == 0)
        #expect(RecordingExtras.segmentsToDelete(durations: [60, 60, 60, 60], keepSeconds: 180) == 1)
        #expect(RecordingExtras.segmentsToDelete(durations: [60, 60, 60, 60], keepSeconds: 100) == 3)
        #expect(RecordingExtras.segmentsToDelete(durations: [600], keepSeconds: 10) == 0)
        #expect(RecordingExtras.segmentsToDelete(durations: [], keepSeconds: 10) == 0)
    }

    @Test func autoDeleteMatching() {
        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)
        func ok(_ n: String, _ m: Date = old, days: Int = 7) -> Bool {
            RecordingExtras.isAutoDeleteCandidate(fileName: n, prefix: "GV", modified: m, now: now, days: days)
        }
        #expect(ok("GV-2024-01-01.mov"))
        #expect(ok("GV-2024-01-01.mp4"))
        #expect(ok("GV-2024-01-01.markers.json"))
        #expect(!ok("GV2024.mov"))
        #expect(!ok("Other-2024.mov"))
        #expect(!ok("GV-2024.png"))
        #expect(!ok("GV-2024.mov", now.addingTimeInterval(-3 * 86_400)))
        #expect(!ok("GV-2024.mov", days: 0))
    }

    @Test func markersSidecar() throws {
        let rec = URL(fileURLWithPath: "/tmp/GV-1.mov")
        #expect(RecordingMarkers.sidecarURL(for: rec).lastPathComponent == "GV-1.markers.json")
        let data = try #require(RecordingMarkers.encode([RecordingMarker(t: 1.5, label: "x")]))
        let back = try JSONDecoder().decode([RecordingMarker].self, from: data)
        #expect(back == [RecordingMarker(t: 1.5, label: "x")])
    }
}
