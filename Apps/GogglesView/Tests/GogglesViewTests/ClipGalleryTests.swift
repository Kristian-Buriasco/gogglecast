import XCTest
@testable import GogglesView

final class ClipGalleryTests: XCTestCase {
    func testFormatDuration() {
        XCTAssertEqual(ClipLibrary.formatDuration(65), "1:05")
        XCTAssertEqual(ClipLibrary.formatDuration(3725), "1:02:05")
        XCTAssertEqual(ClipLibrary.formatDuration(nil), "--:--")
        XCTAssertEqual(ClipLibrary.formatDuration(.nan), "--:--")
    }

    func testSortNewestFirst() {
        let a = Clip(url: URL(fileURLWithPath: "/a.mov"), date: Date(timeIntervalSince1970: 1), size: 1)
        let b = Clip(url: URL(fileURLWithPath: "/b.mov"), date: Date(timeIntervalSince1970: 2), size: 1)
        XCTAssertEqual(ClipLibrary.sortedNewestFirst([a, b]).map(\.name), ["b.mov", "a.mov"])
    }

    func testDecodeMarkers() {
        let d = #"[{"t":5,"label":"b"},{"t":1,"label":"a"},{"t":-2,"label":"x"}]"#.data(using: .utf8)
        XCTAssertEqual(ClipLibrary.decodeMarkers(d).map(\.label), ["a", "b"])
        XCTAssertEqual(ClipLibrary.decodeMarkers(nil), [])
        XCTAssertEqual(ClipLibrary.decodeMarkers(Data("junk".utf8)), [])
    }

    func testTrimOutputNeverOverwrites() {
        let u = URL(fileURLWithPath: "/r/clip.mov")
        XCTAssertEqual(ClipLibrary.trimOutputURL(for: u, exists: { _ in false }).lastPathComponent, "clip-trim.mov")
        let taken: Set<String> = ["clip-trim.mov", "clip-trim-2.mov"]
        XCTAssertEqual(ClipLibrary.trimOutputURL(for: u, exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "clip-trim-3.mov")
    }

    func testClamp() {
        var r = TrimMath.clamp(start: -3, end: 99, duration: 10, movedStart: true)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 10)
        r = TrimMath.clamp(start: 9.9, end: 10, duration: 10, movedStart: true)
        XCTAssertEqual(r.start, 9.5); XCTAssertEqual(r.end, 10)
        r = TrimMath.clamp(start: 0, end: 0.1, duration: 10, movedStart: false)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 0.5)
    }
}
