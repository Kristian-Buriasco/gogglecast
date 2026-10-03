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

    func testOversizedSingleGroupCleared() {
        var w = ReplayWindow<Int>(maxSeconds: 1000, maxBytes: 50)
        w.append(0, pts: 0, bytes: 100, isKey: true)
        XCTAssertTrue(w.entries.isEmpty)
    }

    func testFileName() {
        let n = ReplayBuffer.fileName(for: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!,
                                      prefix: "Foo", ext: "mp4")
        XCTAssertEqual(n, "Foo-replay-1970-01-01-00-00-00.mp4")
    }
}
