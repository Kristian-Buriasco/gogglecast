import AVFoundation
import Combine
import CoreMedia
import Foundation
import GogglesH264
import Testing
@testable import GogglesView

/// Synthetic passthrough samples: the writer never decodes them, so a real parameter set plus
/// placeholder slice bytes are enough to exercise the recorder's file handling.
enum SyntheticStream {
    static let format: CMFormatDescription = {
        try! ParameterSetSplitter.formatDescription(fromBundledBlob: BurnInFixture.spsPPS)
    }()

    /// One sample at `index` of a 30 fps stream starting at host time `base`.
    static func sample(_ index: Int, key: Bool, base: UInt64 = 5_000_000_000_000, payload: Int = 2_000) -> CMSampleBuffer {
        var nal = [UInt8](repeating: 0x55, count: payload)
        nal[0] = key ? 0x65 : 0x41
        var avcc = Data()
        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
        avcc.append(contentsOf: nal)
        return try! DecodeSession.makeSampleBuffer(avccData: avcc, formatDescription: format,
                                                   hostTime: base + UInt64(index) * 33_333_333)
    }
}

/// Mutable clock for the recorder's `now`.
final class RecorderTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private func tempFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeRecorder(clock: RecorderTestClock = RecorderTestClock(), free: Int64 = 50_000_000_000,
                          limits: RecordingExtras.SplitLimits = .init()) -> (Recorder, RecorderTestClock) {
    let r = Recorder()
    r.now = { clock.date }
    r.capacityProvider = { _ in free }
    r.limitsProvider = { limits }
    return (r, clock)
}

/// Waits for main-queue publications.
private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

private func stopped(_ r: Recorder) async -> URL? {
    await withCheckedContinuation { c in r.stop { c.resume(returning: $0) } }
}

@Suite(.serialized)
struct RecorderReliabilityTests {
    // MARK: 1. Crash-safe files

    /// Records 6 s, copies the file while the writer is still open (what is on disk after a crash or
    /// power loss), and checks the copy plays up to the last fragment.
    @Test(arguments: ["mov", "mp4"])
    func partialFileIsPlayableAfterACrash(ext: String) async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (r, _) = makeRecorder()
        let url = dir.appendingPathComponent("crash.\(ext)")
        try r.start(to: url)
        for i in 0..<180 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let copy = dir.appendingPathComponent("copy.\(ext)")
        try FileManager.default.copyItem(at: url, to: copy) // the writer is NOT finished

        let asset = AVURLAsset(url: copy)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(playable)
        #expect(tracks.count == 1)
        #expect(CMTimeGetSeconds(duration) >= 1.5, "at least the first fragments, got \(CMTimeGetSeconds(duration)) s")
        _ = await stopped(r)
    }

    @Test func fragmentIntervalIsAboutTwoSeconds() {
        #expect(CMTimeGetSeconds(Recorder.fragmentInterval) == 2)
        #expect(Recorder.fragmentInterval.timescale == 600)
    }

    // MARK: 2. Failure handling

    @Test func failureStopsOnceAndReportsAPlainMessage() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("gone", isDirectory: true)
        let (r, _) = makeRecorder()
        var failures: [RecordingFailure] = []
        let sub = r.$failure.compactMap { $0 }.sink { failures.append($0) }
        defer { sub.cancel() }
        try r.start(to: folder.appendingPathComponent("x.mov"))
        try FileManager.default.removeItem(at: folder)
        for i in 0..<120 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        await settle()
        #expect(failures.count == 1, "fail() must be idempotent, got \(failures.count)")
        #expect(failures.first?.message.contains("'gone'") == true)
        #expect(failures.first?.message.contains("missing") == true)
        #expect(!r.isRecording)
        #expect(await stopped(r) == nil)
    }

    @Test func failureMessagesMapKnownCauses() {
        let folder = URL(fileURLWithPath: "/tmp/Clips")
        func msg(_ e: Error?) -> String { RecordingProblem.plainMessage(error: e, folder: folder, folderExists: { _ in true }) }
        #expect(msg(NSError(domain: NSCocoaErrorDomain, code: 640)).contains("disk is full"))
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(msg(wrapped).contains("disk is full"))
        #expect(msg(NSError(domain: NSPOSIXErrorDomain, code: 13)).contains("can't write to the folder 'Clips'"))
        #expect(msg(NSError(domain: NSCocoaErrorDomain, code: 4)).contains("missing"))
        #expect(msg(nil) == "Recording couldn't be saved. Check that the folder 'Clips' exists and has free space, then try again.")
        #expect(RecordingProblem.plainMessage(error: nil, folder: folder, folderExists: { _ in false }).contains("missing"))
        #expect(RecordingProblem.unsupportedFormatMessage == "This stream can't be recorded in the chosen format. Try .mov in Settings > Recording.")
    }

    @Test func startErrorsUsePlainSentences() throws {
        let (r, _) = makeRecorder(free: 100_000_000)
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try r.start(to: dir.appendingPathComponent("x.mov"))
            Issue.record("start should refuse below 500 MB")
        } catch {
            #expect(error.localizedDescription.contains("less than 500 MB"))
        }
    }

    // MARK: 3. Saved file check

    @Test func stopReportsADeletedFolderInsteadOfSuccess() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (r, _) = makeRecorder()
        try r.start(to: folder.appendingPathComponent("x.mov"))
        for i in 0..<30 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        try FileManager.default.removeItem(at: folder)
        let result = await stopped(r)
        await settle()
        #expect(result == nil)
        #expect(r.failure?.message.contains("gone") == true)
    }

    @Test func stopReturnsTheFileWhenItExists() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (r, _) = makeRecorder()
        let url = dir.appendingPathComponent("ok.mov")
        try r.start(to: url)
        for i in 0..<30 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        #expect(await stopped(r) == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: 4. Free space

    @Test func lowSpaceDuringRecordingFinishesTheFileCleanly() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecorderTestClock()
        var free: Int64 = 50_000_000_000
        let r = Recorder()
        r.now = { clock.date }
        r.capacityProvider = { _ in free }
        r.limitsProvider = { .init() }
        let url = dir.appendingPathComponent("low.mov")
        try r.start(to: url)
        for i in 0..<30 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        clock.advance(6)
        free = 100_000_000
        r.enqueue(SyntheticStream.sample(30, key: false))
        await settle()
        #expect(!r.isRecording)
        #expect(r.failure == nil)
        let stop = try #require(r.autoStop)
        #expect(stop.url == url)
        #expect(stop.message.contains("almost full"))
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0.5)
    }

    @Test func spaceIsOnlyPolledEveryFiveSeconds() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = RecorderTestClock()
        var calls = 0
        let r = Recorder()
        r.now = { clock.date }
        r.capacityProvider = { _ in calls += 1; return 50_000_000_000 }
        r.limitsProvider = { .init() }
        try r.start(to: dir.appendingPathComponent("p.mov"))
        let atStart = calls
        for i in 0..<60 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        #expect(calls == atStart)
        clock.advance(5.1)
        r.enqueue(SyntheticStream.sample(60, key: false))
        #expect(calls == atStart + 1)
        _ = await stopped(r)
    }

    // MARK: 5. Slow disk

    @Test func slowDiskCountsDropsAndSwitchesToTheReencodedStream() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (r, _) = makeRecorder()
        let hub = ReencodeHub(source: { nil })
        r.keyframeHub = hub
        let url = dir.appendingPathComponent("slow.mov")
        try r.start(to: url)
        r.enqueue(SyntheticStream.sample(0, key: true))
        var blocked = false
        r.readinessOverride = { !blocked }
        blocked = true
        for i in 1...6 { r.enqueue(SyntheticStream.sample(i, key: false)) }
        #expect(r.droppedFrameCount == 6)
        await settle()
        #expect(r.diskNote?.contains("Disk is slow") == true)
        blocked = false
        // The re-encoded stream's first keyframe closes the damaged raw segment and starts part 2.
        r.enqueueFromHub(SyntheticStream.sample(10, key: true))
        r.enqueueFromHub(SyntheticStream.sample(11, key: false))
        // Raw samples are ignored from now on.
        r.enqueue(SyntheticStream.sample(12, key: false))
        _ = await stopped(r)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: RecordingExtras.partURL(base: url, part: 2).path))
    }

    @Test func fewDropsDoNotSwitchStreams() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let (r, _) = makeRecorder()
        r.keyframeHub = ReencodeHub(source: { nil })
        let url = dir.appendingPathComponent("few.mov")
        try r.start(to: url)
        r.enqueue(SyntheticStream.sample(0, key: true))
        var blocked = false
        r.readinessOverride = { !blocked }
        blocked = true
        for i in 1...3 { r.enqueue(SyntheticStream.sample(i, key: false)) }
        blocked = false
        r.enqueue(SyntheticStream.sample(4, key: false))
        r.enqueueFromHub(SyntheticStream.sample(10, key: true)) // no switch pending: ignored
        _ = await stopped(r)
        #expect(!FileManager.default.fileExists(atPath: RecordingExtras.partURL(base: url, part: 2).path))
    }

    // MARK: 6. Rotation on a raw stream

    @Test func dueSplitOnARawStreamSwitchesToTheHubAndRotates() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        var limits = RecordingExtras.SplitLimits(); limits.maxSeconds = 1
        let (r, clock) = makeRecorder(limits: limits)
        r.keyframeHub = ReencodeHub(source: { nil })
        let url = dir.appendingPathComponent("split.mov")
        try r.start(to: url)
        // 2 s of one IDR then P-frames: due after 1 s, but no keyframe ever arrives.
        for i in 0..<60 { r.enqueue(SyntheticStream.sample(i, key: i == 0)) }
        r.enqueueFromHub(SyntheticStream.sample(100, key: true))
        #expect(!FileManager.default.fileExists(atPath: RecordingExtras.partURL(base: url, part: 2).path), "no switch before the wait")
        clock.advance(Recorder.splitKeyframeWait + 0.1)
        r.enqueue(SyntheticStream.sample(61, key: false))
        r.enqueueFromHub(SyntheticStream.sample(100, key: true))
        r.enqueueFromHub(SyntheticStream.sample(101, key: false))
        _ = await stopped(r)
        let part2 = RecordingExtras.partURL(base: url, part: 2)
        #expect(FileManager.default.fileExists(atPath: part2.path))
        #expect(try await AVURLAsset(url: url).load(.isPlayable))
    }

    @Test func dueSplitWithAKeyframeRotatesImmediately() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        var limits = RecordingExtras.SplitLimits(); limits.maxSeconds = 1
        let (r, _) = makeRecorder(limits: limits)
        let url = dir.appendingPathComponent("k.mov")
        try r.start(to: url)
        for i in 0..<60 { r.enqueue(SyntheticStream.sample(i, key: i % 45 == 0)) }
        _ = await stopped(r)
        #expect(FileManager.default.fileExists(atPath: RecordingExtras.partURL(base: url, part: 2).path))
    }

    @Test func loopNeverDeletesWhenTheRotatedSegmentFailed() {
        let finished = [(URL(fileURLWithPath: "/a"), 60.0), (URL(fileURLWithPath: "/b"), 60.0), (URL(fileURLWithPath: "/c"), 60.0)]
            .map { (url: $0.0, duration: $0.1) }
        #expect(RecordingExtras.loopDeletions(finished: finished, keepSeconds: 100, lastSegmentCompleted: false).isEmpty)
        #expect(RecordingExtras.loopDeletions(finished: finished, keepSeconds: 100, lastSegmentCompleted: true).count == 2)
    }

    // MARK: 9. Stabilizer needs the re-encoded stream

    @Test func stabilizerRequiresTheReencodedStream() {
        #expect(!OutputProcessor.needsReencodedStream(outputActive: false, stabilizerOn: false))
        #expect(OutputProcessor.needsReencodedStream(outputActive: false, stabilizerOn: true))
        #expect(OutputProcessor.needsReencodedStream(outputActive: true, stabilizerOn: false))
    }
}

struct RecordingExtrasSafetyTests {
    private let now = Date()
    private func ok(_ name: String, age days: Double, setting: Int = 7) -> Bool {
        RecordingExtras.isAutoDeleteCandidate(fileName: name, prefix: "GV", modified: now.addingTimeInterval(-days * 86_400),
                                              now: now, days: setting)
    }

    @Test func replayClipsAndFreshFilesAreNeverAutoDeleted() {
        #expect(ok("GV-2024-01-01.mov", age: 30))
        #expect(!ok("GV-replay-2024-01-01.mov", age: 30))
        #expect(!ok("GV-replay-2024-01-01.json", age: 30))
        #expect(!ok("GV-2024-01-01.mov", age: 0.5, setting: 1))
        #expect(!ok("GV-2024-01-01.mov", age: 6.9))
        #expect(RecordingExtras.minAge == 86_400)
    }

    @Test func cleanupTellsTheUserWhatItDid() {
        var told: [String] = []
        RecordingExtras.runCleanup(clean: { 3 }, notify: { told.append($0) })
        #expect(told == ["Moved 3 old recordings to the Trash"])
        RecordingExtras.runCleanup(clean: { 1 }, notify: { told.append($0) })
        #expect(told.last == "Moved 1 old recording to the Trash")
        RecordingExtras.runCleanup(clean: { 0 }, notify: { told.append($0) })
        #expect(told.count == 2)
    }

    @Test func settingsWording() {
        #expect(RecordingExtras.valueLabel(0, unit: "min") == "Off")
        #expect(RecordingExtras.valueLabel(30, unit: "min") == "30 min")
        let text = RecordingExtras.autoDeleteConfirmation(days: 14, folder: URL(fileURLWithPath: "/Users/me/Movies/GogglesView"))
        #expect(text == "GogglesView will move recordings older than 14 days in /Users/me/Movies/GogglesView to the Trash every time it launches. Continue?")
    }
}
