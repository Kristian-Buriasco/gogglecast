import XCTest
@testable import GogglesView

final class ClipSearchTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    // Wed 2026-10-07 12:00 UTC
    private let now = Date(timeIntervalSince1970: 1_791_374_400)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ name: String, daysAgo: Double = 0, size: Int64 = 1, duration: Double? = nil,
                      tags: [String] = [], note: String = "", fav: Bool = false, goggles: String? = nil, serial: String? = nil) -> Clip {
        var m = ClipMetadata()
        m.tags = tags; m.note = note; m.favourite = fav; m.gogglesName = goggles; m.gogglesSerial = serial
        return Clip(url: URL(fileURLWithPath: "/r/\(name).mov"), date: now.addingTimeInterval(-daysAgo * 86_400), size: size,
                    duration: duration, metadata: m.isEmpty ? nil : m)
    }

    private func names(_ f: ClipFilter, _ clips: [Clip]) -> [String] {
        ClipIndex.apply(f, to: clips, now: now, calendar: cal).map { $0.url.deletingPathExtension().lastPathComponent }
    }

    // MARK: metadata

    func testRoundTrip() throws {
        let u = dir.appendingPathComponent("a.mov")
        var m = ClipMetadata()
        m.tags = ["fpv", "Coast"]; m.note = "windy"; m.favourite = true; m.gogglesName = "G"; m.width = 1920; m.height = 1080; m.fps = 60
        XCTAssertTrue(ClipMetadataStore.write(m, for: u))
        XCTAssertEqual(ClipMetadataStore.sidecarURL(for: u).lastPathComponent, "a.gvmeta.json")
        XCTAssertEqual(ClipMetadataStore.read(for: u), m)
    }

    func testTolerantDecoding() {
        let json = #"{"version":9,"tags":["A","a"," #b "],"note":5,"favourite":"yes","future":{"x":1},"width":1280}"#
        let m = ClipMetadataStore.decode(Data(json.utf8))
        XCTAssertEqual(m?.tags, ["A", "b"])
        XCTAssertEqual(m?.note, "")
        XCTAssertEqual(m?.favourite, false)
        XCTAssertEqual(m?.width, 1280)
    }

    func testCorruptFileIgnoredAndOverwritable() throws {
        let u = dir.appendingPathComponent("a.mov")
        try Data("not json".utf8).write(to: ClipMetadataStore.sidecarURL(for: u))
        XCTAssertNil(ClipMetadataStore.read(for: u))
        let m = ClipMetadataStore.update(for: u) { $0.tags = ["x"] }
        XCTAssertEqual(ClipMetadataStore.read(for: u), m)
    }

    func testEmptyMetadataRemovesSidecar() {
        let u = dir.appendingPathComponent("a.mov")
        ClipMetadataStore.update(for: u) { $0.favourite = true }
        XCTAssertNotNil(ClipMetadataStore.read(for: u))
        ClipMetadataStore.update(for: u) { $0.favourite = false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipMetadataStore.sidecarURL(for: u).path))
    }

    func testRecordInfoMergeKeepsUserData() {
        var m = ClipMetadata(); m.tags = ["keep"]
        let out = ClipMetadataStore.merge(ClipRecordInfo(gogglesName: "G", gogglesSerial: "S1", width: 1920, height: 1080, fps: 60), into: m)
        XCTAssertEqual(out.tags, ["keep"]); XCTAssertEqual(out.gogglesName, "G"); XCTAssertEqual(out.height, 1080)
    }

    func testTagNormalization() {
        XCTAssertEqual(ClipMetadata.parseTags("Fpv, fpv; #Café ,  ,  two   words"), ["Fpv", "Café", "two words"])
        let m = ClipMetadata().applying(add: ["a", "b"]).applying(add: ["B", "c"], remove: ["A"])
        XCTAssertEqual(m.tags, ["b", "c"])
    }

    // MARK: filtering

    func testTextMatchesNameNoteTagsGogglesDiacritics() {
        let clips = [clip("Harbour-run", note: "Windy day"), clip("Ridge", tags: ["Café"]), clip("Beach", goggles: "Blue Goggles"), clip("Other")]
        var f = ClipFilter()
        f.text = "harbour"; XCTAssertEqual(names(f, clips), ["Harbour-run"])
        f.text = "WINDY"; XCTAssertEqual(names(f, clips), ["Harbour-run"])
        f.text = "cafe"; XCTAssertEqual(names(f, clips), ["Ridge"])
        f.text = "blue"; XCTAssertEqual(names(f, clips), ["Beach"])
        f.text = "ridge cafe"; XCTAssertEqual(names(f, clips), ["Ridge"])
        f.text = "ridge windy"; XCTAssertEqual(names(f, clips), [])
        f.text = "  "; XCTAssertEqual(names(f, clips).count, 4)
    }

    func testTagAnyAll() {
        let clips = [clip("a", tags: ["x", "y"]), clip("b", tags: ["x"]), clip("c", tags: ["z"]), clip("d")]
        var f = ClipFilter(); f.tags = ["X", "y"]
        f.tagMatch = .any; XCTAssertEqual(Set(names(f, clips)), ["a", "b"])
        f.tagMatch = .all; XCTAssertEqual(names(f, clips), ["a"])
    }

    func testDatePresetsWithInjectedClock() {
        let clips = [clip("today", daysAgo: 0.1), clip("old3", daysAgo: 3), clip("old20", daysAgo: 20), clip("old60", daysAgo: 60)]
        var f = ClipFilter(); f.sort = .oldest
        f.date = .today; XCTAssertEqual(names(f, clips), ["today"])
        f.date = .last7Days; XCTAssertEqual(names(f, clips), ["old3", "today"])
        f.date = .last30Days; XCTAssertEqual(names(f, clips), ["old20", "old3", "today"])
        let lo = now.addingTimeInterval(-4 * 86_400), hi = now.addingTimeInterval(-3 * 86_400)
        f.date = .custom(lo...hi); XCTAssertEqual(names(f, clips), ["old3"])
        f.date = .custom(hi...hi); XCTAssertEqual(names(f, clips), ["old3"])
    }

    func testGogglesAndFavouritesCombine() {
        let clips = [clip("a", fav: true, goggles: "A", serial: "1"), clip("b", goggles: "A", serial: "1"),
                     clip("c", fav: true, goggles: "B", serial: "2"), clip("d")]
        XCTAssertEqual(ClipIndex.knownGoggles(clips).map(\.label), ["A", "B", "Unknown goggles"])
        var f = ClipFilter(); f.goggles = "1"
        XCTAssertEqual(Set(names(f, clips)), ["a", "b"])
        f.favouritesOnly = true; XCTAssertEqual(names(f, clips), ["a"])
        f.goggles = ClipGoggles.unknownKey; f.favouritesOnly = false; XCTAssertEqual(names(f, clips), ["d"])
    }

    func testSorting() {
        let clips = [clip("b10", daysAgo: 1, size: 5, duration: 10), clip("b2", daysAgo: 3, size: 9, duration: 30),
                     clip("a", daysAgo: 2, size: 1, duration: nil)]
        var f = ClipFilter()
        f.sort = .newest; XCTAssertEqual(names(f, clips), ["b10", "a", "b2"])
        f.sort = .oldest; XCTAssertEqual(names(f, clips), ["b2", "a", "b10"])
        f.sort = .longest; XCTAssertEqual(names(f, clips), ["b2", "b10", "a"])
        f.sort = .largest; XCTAssertEqual(names(f, clips), ["b2", "b10", "a"])
        f.sort = .name; XCTAssertEqual(names(f, clips), ["a", "b2", "b10"])
    }

    func testFacetsAndLabels() {
        let clips = [clip("a", tags: ["x", "y"]), clip("b", tags: ["X"]), clip("c")]
        XCTAssertEqual(ClipIndex.allTags(clips).map(\.tag), ["x", "y"])
        XCTAssertEqual(ClipIndex.allTags(clips).map(\.count), [2, 1])
        XCTAssertEqual(ClipIndex.countLabel(shown: 12, total: 240), "12 of 240 clips")
        XCTAssertEqual(ClipIndex.countLabel(shown: 1, total: 1), "1 clip")
        var f = ClipFilter(); f.sort = .name
        XCTAssertFalse(f.isActive); f.favouritesOnly = true; XCTAssertTrue(f.isActive)
        f.clear(); XCTAssertFalse(f.isActive); XCTAssertEqual(f.sort, .name)
        let vis = [clip("a"), clip("b"), clip("c"), clip("d")]
        XCTAssertEqual(ClipIndex.range(from: vis[3].url, to: vis[1].url, in: vis).count, 3)
        XCTAssertEqual(ClipIndex.range(from: nil, to: vis[1].url, in: vis), [vis[1].url])
    }

    func testFiltersHundredsOfClipsQuickly() {
        let clips = (0..<600).map { clip("c\($0)", daysAgo: Double($0) / 10, tags: ["t\($0 % 7)"], note: "note \($0)") }
        var f = ClipFilter(); f.text = "note 5"; f.tags = ["t1", "t2"]
        measure { _ = ClipIndex.apply(f, to: clips, now: now, calendar: cal) }
    }

    // MARK: files

    func testTrashMovesSidecarsAlong() throws {
        let u = dir.appendingPathComponent("a.mov")
        try Data("v".utf8).write(to: u)
        try Data("[]".utf8).write(to: ClipLibrary.sidecarURL(for: u))
        ClipMetadataStore.update(for: u) { $0.tags = ["x"] }
        let other = dir.appendingPathComponent("b.mov")
        try Data("v".utf8).write(to: other)
        ClipMetadataStore.update(for: other) { $0.tags = ["keep"] }
        var trashed: [String] = []
        ClipLibrary.trashFiles(for: u) { trashed.append($0.lastPathComponent) }
        XCTAssertEqual(trashed, ["a.mov", "a.markers.json", "a.gvmeta.json"])
    }

    func testTrimCarryOver() throws {
        let src = dir.appendingPathComponent("a.mov"), out = dir.appendingPathComponent("a-trim.mov")
        ClipMetadataStore.update(for: src) { $0.tags = ["x"]; $0.favourite = true; $0.gogglesName = "G" }
        XCTAssertTrue(ClipMetadataStore.carryOver(from: src, to: out))
        let m = try XCTUnwrap(ClipMetadataStore.read(for: out))
        XCTAssertEqual(m.tags, ["x"]); XCTAssertTrue(m.favourite); XCTAssertEqual(m.gogglesName, "G")
        XCTAssertEqual(m.note, "Trimmed from a.mov")
        ClipMetadataStore.update(for: src) { $0.note = "first" }
        ClipMetadataStore.carryOver(from: src, to: out)
        XCTAssertEqual(ClipMetadataStore.read(for: out)?.note, "first\nTrimmed from a.mov")
    }

    func testClipWithoutMetadataStillListed() throws {
        let u = dir.appendingPathComponent("plain.mov")
        try Data("v".utf8).write(to: u)
        let clips = ClipLibrary.scan(dir)
        XCTAssertEqual(clips.count, 1)
        XCTAssertNil(clips[0].metadata)
        XCTAssertEqual(ClipIndex.apply(ClipFilter(), to: clips).count, 1)
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(AccessibilityLabels.clipCard(name: "a.mov", date: "d", duration: "0:10", size: "1 MB", tags: ["x", "y"], favourite: true),
                       "a.mov, d, 0:10, 1 MB, tags x, y, favourite")
        XCTAssertEqual(AccessibilityLabels.favouriteToggle(isOn: false), "Add to favourites")
    }
}
