import XCTest
@testable import GogglesView

final class ReplayBufferTests: XCTestCase {
    private func fill(_ w: inout ReplayWindow<Int>, seconds: Int, gop: Int = 10, fps: Int = 10, bytes: Int = 100) {
        for i in 0..<(seconds * fps) {
            w.append(i, pts: Double(i) / Double(fps), bytes: bytes, isKey: i % gop == 0)
        }
    }

    func testTrimStartsAtKeyframeAndKeepsWindow() {
        var w = ReplayWindow<Int>(maxSeconds: 10, maxBytes: .max)
        fill(&w, seconds: 35)
        XCTAssertTrue(w.entries.first!.isKey)
        XCTAssertGreaterThanOrEqual(w.duration, 9.8)
        XCTAssertLessThanOrEqual(w.duration, 11.0)
    }

    func testIgnoresLeadingNonKeyframes() {
        var w = ReplayWindow<Int>(maxSeconds: 10, maxBytes: .max)
        w.append(0, pts: 0, bytes: 1, isKey: false)
        XCTAssertTrue(w.entries.isEmpty)
    }

    func testByteCapDropsOldestGroups() {
        var w = ReplayWindow<Int>(maxSeconds: 1000, maxBytes: 2500)
        fill(&w, seconds: 10)
        XCTAssertLessThanOrEqual(w.totalBytes, 2500)
        XCTAssertTrue(w.entries.first!.isKey)
        XCTAssertEqual(w.totalBytes, w.entries.reduce(0) { $0 + $1.bytes })
    }

    func testOversizedSingleGroupIsKeptNotDiscarded() {
        var w = ReplayWindow<Int>(maxSeconds: 1000, maxBytes: 50)
        w.append(0, pts: 0, bytes: 70, isKey: true)
        XCTAssertEqual(w.entries.count, 1, "a lone group over the cap is kept until a later keyframe lets it go")
        w.append(1, pts: 0.1, bytes: 10, isKey: false)
        XCTAssertEqual(w.entries.count, 2)
        w.append(2, pts: 1.0, bytes: 10, isKey: true)
        XCTAssertEqual(w.entries.first?.item, 2, "the older group goes once a newer keyframe exists")
        XCTAssertEqual(w.totalBytes, 10)
    }

    func testByteCapNeverEmptiesTheBufferWithSteadyKeyframes() {
        var w = ReplayWindow<Int>(maxSeconds: 1000, maxBytes: 1500)
        fill(&w, seconds: 20, gop: 10, fps: 10, bytes: 100) // each group is 1000 bytes; the cap fits one and a half
        XCTAssertFalse(w.entries.isEmpty)
        XCTAssertTrue(w.entries.first!.isKey)
    }

    func testRunawayGroupWithoutKeyframeStartsOver() {
        var w = ReplayWindow<Int>(maxSeconds: 1000, maxBytes: 100)
        w.append(0, pts: 0, bytes: 90, isKey: true)
        for i in 1...5 { w.append(i, pts: Double(i), bytes: 50, isKey: false) }
        XCTAssertTrue(w.entries.isEmpty, "past twice the cap with no keyframe, wait for a fresh one")
        w.append(9, pts: 9, bytes: 10, isKey: true)
        XCTAssertEqual(w.entries.count, 1)
    }

    func testAchievableWindow() {
        XCTAssertEqual(ReplayPrefs.achievableSeconds(requested: 120, bitrateMbps: 20), 107)
        XCTAssertEqual(ReplayPrefs.achievableSeconds(requested: 30, bitrateMbps: 20), 30)
        XCTAssertEqual(ReplayPrefs.achievableSeconds(requested: 120, bitrateMbps: 60), 35)
    }

    func testReplayNeedsReencodedStream() {
        XCTAssertFalse(ReplayPrefs.isAvailable(reencode: false, outputActive: false))
        XCTAssertTrue(ReplayPrefs.isAvailable(reencode: true, outputActive: false))
        XCTAssertTrue(ReplayPrefs.isAvailable(reencode: false, outputActive: true))
        XCTAssertEqual(ReplayPrefs.unavailableMessage, "Instant replay needs the keyframe encoder. Turn it on in Settings > Streaming.")
    }

    func testFileName() {
        let n = ReplayBuffer.fileName(for: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!,
                                      prefix: "Foo", ext: "mp4")
        XCTAssertEqual(n, "Foo-replay-1970-01-01-00-00-00.mp4")
    }
}
