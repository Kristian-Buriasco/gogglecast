import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import GogglesView

private func tempFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stopped(_ r: Recorder) async -> URL? {
    await withCheckedContinuation { c in r.stop { c.resume(returning: $0) } }
}

/// Chapter titles and start times as a player would list them (the API player apps use).
private func chapters(of url: URL) async throws -> [(title: String, start: Double)] {
    let asset = AVURLAsset(url: url)
    let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en", "und"])
    var out: [(String, Double)] = []
    for g in groups {
        let title = try await g.items.first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
        out.append((title ?? "", g.timeRange.start.seconds))
    }
    return out
}

@Suite(.serialized)
struct RecordingChaptersTests {
    /// Records ~6 s of synthetic frames with three markers dropped between frame batches.
    private func record(ext: String, in dir: URL, marks: [(Int, String)], frames: Int = 180,
                        interrupt: Bool = false) async throws -> (URL, Recorder) {
        let r = Recorder()
        r.capacityProvider = { _ in 50_000_000_000 }
        r.limitsProvider = { .init() }
        let url = dir.appendingPathComponent("rec.\(ext)")
        try r.start(to: url)
        for i in 0..<frames {
            r.enqueue(SyntheticStream.sample(i, key: i % 30 == 0))
            for m in marks where m.0 == i { r.addMarker(label: m.1) }
        }
        return (url, r)
    }

    @Test(arguments: ["mov", "mp4"])
    func markersBecomeChapters(ext: String) async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, r) = try await record(ext: ext, in: dir, marks: [(30, "Highlight"), (90, "Crash"), (150, "Landing")])
        let done = await stopped(r)
        #expect(r.droppedFrameCount == 0)
        #expect(done == url)

        let found = try await chapters(of: url)
        #expect(found.map(\.title) == ["Highlight", "Crash", "Landing"])
        let expected = [30.0 / 30, 90.0 / 30, 150.0 / 30]
        for (c, e) in zip(found, expected) { #expect(abs(c.start - e) < 0.1, "\(c) vs \(e)") }

        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let dur = try await asset.load(.duration).seconds
        #expect(abs(dur - 6) < 0.3, "duration \(dur)")
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }

    /// Chapters are only added when the recording is finished, so what is on disk during a recording (the
    /// state after a crash) is still the plain fragmented video file: playable up to the last fragment.
    @Test func fileCopiedMidRecordingStaysPlayable() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, r) = try await record(ext: "mov", in: dir, marks: [(30, "Highlight"), (90, "Crash"), (150, "Landing")])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let copy = dir.appendingPathComponent("copy.mov")
        try FileManager.default.copyItem(at: url, to: copy) // the writer is NOT finished
        let asset = AVURLAsset(url: copy)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds >= 1.5)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        _ = await stopped(r)
    }

    @Test func rewriteKeepsEverySampleAndStaysFragmented() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.mov")
        let r0 = Recorder()
        r0.capacityProvider = { _ in 50_000_000_000 }; r0.limitsProvider = { .init() }
        try r0.start(to: plain)
        for i in 0..<180 { r0.enqueue(SyntheticStream.sample(i, key: i % 30 == 0)) }
        _ = await stopped(r0)
        let (marked, r) = try await record(ext: "mov", in: dir, marks: [(30, "A"), (90, "B")])
        _ = await stopped(r)

        func videoSamples(_ url: URL) async throws -> (count: Int, bytes: Int, lastPTS: Double) {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out); reader.startReading()
            var count = 0, bytes = 0, last = 0.0
            while let s = out.copyNextSampleBuffer() {
                count += CMSampleBufferGetNumSamples(s); bytes += CMSampleBufferGetTotalSampleSize(s)
                last = max(last, CMSampleBufferGetPresentationTimeStamp(s).seconds)
            }
            return (count, bytes, last)
        }
        let a = try await videoSamples(plain), b = try await videoSamples(marked)
        #expect(a.count == 180 && b.count == 180)
        #expect(a.bytes == b.bytes)
        #expect(abs(a.lastPTS - b.lastPTS) < 0.002)
        let bytes = try Data(contentsOf: marked)
        #expect(bytes.range(of: Data("moof".utf8)) != nil, "the rewritten file keeps its movie fragments")
        #expect(try await chapters(of: marked).map(\.title) == ["A", "B"])
    }

    @Test func aFailedRewriteLeavesTheOriginalUntouched() throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.mov")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try payload.write(to: junk)
        let outcome = ChapterRewriter.addChapters([(1, "x")], to: junk)
        #expect(outcome != .added(chapters: 1))
        #expect(try Data(contentsOf: junk) == payload)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["junk.mov"], "temporary file removed, got \(leftovers)")
        // Missing file and empty chapter list are skipped quietly.
        #expect(ChapterRewriter.addChapters([(1, "x")], to: dir.appendingPathComponent("nope.mov")) != .added(chapters: 1))
        #expect(ChapterRewriter.addChapters([], to: junk) == .skipped("no markers"))
    }

    @Test func verificationRejectsAFileWithoutTheExpectedChapters() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, r) = try await record(ext: "mov", in: dir, marks: [(30, "A")])
        _ = await stopped(r)
        let problem = await Task.detached { ChapterRewriter.verify(copy: url, expectedDuration: 6, expectedTitles: ["A", "B"]) }.value
        #expect(problem?.contains("chapters read back") == true)
        let wrongDuration = await Task.detached { ChapterRewriter.verify(copy: url, expectedDuration: 9, expectedTitles: ["A"]) }.value
        #expect(wrongDuration?.contains("duration changed") == true)
        let fine = await Task.detached { ChapterRewriter.verify(copy: url, expectedDuration: 6, expectedTitles: ["A"]) }.value
        #expect(fine == nil)
    }

    @Test func eachSplitPartGetsItsOwnChapters() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = Recorder()
        r.capacityProvider = { _ in 50_000_000_000 }
        r.limitsProvider = { RecordingExtras.SplitLimits(maxSeconds: 3, maxBytes: nil, loopKeepSeconds: nil) }
        let url = dir.appendingPathComponent("split.mov")
        try r.start(to: url)
        for i in 0..<240 {
            // Keyframe every second so the split has clean cut points.
            r.enqueue(SyntheticStream.sample(i, key: i % 30 == 0))
            if i == 20 { r.addMarker(label: "First") }
            if i == 150 { r.addMarker(label: "Second") }
        }
        _ = await stopped(r)
        let part1 = try await chapters(of: url)
        let part2 = try await chapters(of: RecordingExtras.partURL(base: url, part: 2))
        #expect(part1.map(\.title) == ["First"])
        #expect(part2.map(\.title) == ["Second"])
        let secondStart = try #require(part2.first?.start)
        #expect(secondStart >= 0 && secondStart < 3.2, "relative to its own part, got \(secondStart)")
    }

    @Test func markersBeforeTheFirstFrameStillBecomeChapters() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = Recorder()
        r.capacityProvider = { _ in 50_000_000_000 }
        r.limitsProvider = { .init() }
        let url = dir.appendingPathComponent("early.mov")
        try r.start(to: url)
        r.addMarker(label: "Early")
        for i in 0..<60 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        _ = await stopped(r)
        #expect(try await chapters(of: url).map(\.title) == ["Early"])
    }

    @Test func recordingWithoutMarkersStillWorks() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, r) = try await record(ext: "mov", in: dir, marks: [], frames: 60)
        #expect(await stopped(r) == url)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(try await chapters(of: url).isEmpty)
    }

    /// A passthrough trim (what TrimView exports) keeps the chapters in the range, moved to the new start.
    @Test func passthroughTrimKeepsChaptersInsideTheRange() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (url, r) = try await record(ext: "mov", in: dir, marks: [(30, "Highlight"), (90, "Crash"), (150, "Landing")])
        _ = await stopped(r)
        let out = dir.appendingPathComponent("trim.mov")
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough))
        session.outputURL = out
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600),
                                        end: CMTime(seconds: 5.5, preferredTimescale: 600))
        await session.export()
        #expect(session.status == .completed)
        let found = try await chapters(of: out)
        // The export keeps the chapter that was already running at the cut ("Highlight", now from 0 s).
        #expect(found.map(\.title) == ["Highlight", "Crash", "Landing"])
        for (c, e) in zip(found, [0.0, 1.0, 3.0]) { #expect(abs(c.start - e) < 0.1, "\(c) vs \(e)") }
    }
}

struct ChapterPlanTests {
    @Test func chaptersLastUntilTheNextOneAndTheLastUntilTheEnd() {
        let e = ChapterPlan.entries(for: [(1, "A"), (3, "B"), (5, "C")], duration: 6)
        #expect(e == [.init(start: 1, duration: 2, title: "A"), .init(start: 3, duration: 2, title: "B"),
                      .init(start: 5, duration: 1, title: "C")])
    }

    @Test func closeOrUnsortedStartsAreSeparatedAndOrdered() {
        let e = ChapterPlan.entries(for: [(2, "B"), (1, "A"), (1, "A2")], duration: 10)
        #expect(e.map(\.title) == ["A", "A2", "B"])
        for (x, y) in zip(e, e.dropFirst()) { #expect(y.start - x.start >= ChapterPlan.minSpacing - 1e-9) }
        #expect(e.allSatisfy { $0.duration >= ChapterPlan.minSpacing - 1e-9 })
    }

    @Test func chaptersBeyondTheEndAreDroppedAndNegativeStartsClamped() {
        let e = ChapterPlan.entries(for: [(-5, "Early"), (9.95, "Late"), (20, "Gone")], duration: 10)
        #expect(e.map(\.title) == ["Early"])
        #expect(e.first?.start == 0)
        #expect(ChapterPlan.entries(for: [(0, "x")], duration: 0.05).isEmpty)
    }
}
