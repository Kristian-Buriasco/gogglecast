import AVFoundation
import AppKit
import CoreMedia
import Foundation

/// Records the passthrough H.264 stream to a .mov via `AVAssetWriter`.
/// Registered as an extra `DecodeSession` consumer; `enqueue` may be called
/// from any queue. The writer is created lazily at the first keyframe after
/// `start(to:)` (it needs a format description, and the file must begin on a
/// sync sample to be decodable).
final class Recorder: ObservableObject, SampleBufferRendering {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var markers: [RecordingMarker] = []
    /// Set once when a recording fails and is stopped. The host view shows an alert for each new value.
    @Published private(set) var failure: RecordingFailure?
    /// Set when the recorder finished the file by itself (for example, the disk is nearly full).
    @Published private(set) var autoStop: RecordingAutoStop?
    /// Small status line while the disk can't keep up, for example "Disk is slow, 12 frames dropped".
    @Published private(set) var diskNote: String?

    init() { RecordingExtras.runLaunchCleanupOnce() }

    /// Supplies goggles/resolution info for the clip's `.gvmeta.json` sidecar; set by the host view.
    var metadataProvider: (() -> ClipRecordInfo?)?

    private let lock = NSLock()
    private var url: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastPTS: CMTime?
    private var armed = false
    // Auto-split / loop state (guarded by `lock`).
    private var baseURL: URL?
    private var limits = RecordingExtras.SplitLimits()
    private var part = 1
    private var sessionStart: CMTime?
    private var segmentBytes: Int64 = 0
    private var sessionElapsed: TimeInterval = 0
    private var finished: [(url: URL, duration: TimeInterval)] = []
    private var pendingMarkers: [RecordingMarker] = []

    // Reliability state (guarded by `lock`).
    /// Free-space source for a folder; nil means unknown. Replaced in tests.
    var capacityProvider: (URL) -> Int64? = Recorder.volumeCapacity
    /// Clock for the keyframe wait, free-space polling and split deadlines. Replaced in tests.
    var now: () -> Date = Date.init
    /// Test seam: overrides `AVAssetWriterInput.isReadyForMoreMediaData`.
    var readinessOverride: (() -> Bool)?
    /// Split and loop limits for a new recording; replaced in tests.
    var limitsProvider: () -> RecordingExtras.SplitLimits = { RecordingExtras.currentLimits() }
    private var lastSpaceCheck = Date.distantPast
    private var consecutiveDrops = 0
    private var totalDrops = 0
    private var lastDropAt = Date.distantPast
    private var lastDropPublish = Date.distantPast
    private var pendingHubSwitch = false
    private var splitDueSince: Date?

    static let minFreeBytes: Int64 = 500_000_000
    static let spaceCheckInterval: TimeInterval = 5
    /// Passthrough frames that may be dropped in a row before switching to the re-encoded stream.
    static let slowDiskDropThreshold = 3
    /// How long a due split or loop rotation waits for a keyframe before switching to the re-encoded stream.
    static let splitKeyframeWait: TimeInterval = 2
    /// Movie fragments let a file be played up to the last fragment even if the app or the drive dies mid-recording.
    static let fragmentInterval = CMTime(value: 1200, timescale: 600)

    var droppedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return totalDrops }

    static func volumeCapacity(at folder: URL) -> Int64? {
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage { return n }
        return v?.volumeAvailableCapacity.map { Int64($0) }
    }

    // MARK: - Pure helpers (unit-tested)

    static let minFrameSpacing = CMTime(value: 2, timescale: 1000)

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/GogglesView", isDirectory: true)
    }

    static func fileName(
        for date: Date, timeZone: TimeZone = .current,
        prefix: String = "GogglesView", ext: String = "mov"
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "\(prefix)-\(f.string(from: date)).\(ext)"
    }

    static func defaultURL(date: Date = Date()) -> URL {
        RecordingPrefs.directory.appendingPathComponent(
            fileName(for: date, prefix: RecordingPrefs.prefix, ext: RecordingPrefs.container.ext))
    }

    /// How long an armed recorder waits for an IDR before falling back to re-encoding the decoded picture.
    static let keyframeWait: TimeInterval = 1
    private var armedAt: Date?
    private var framesSeenWhileArmed = 0

    // Mid-stream fallback. The goggles send one IDR when Share Liveview starts and none after, so a
    // recording started later cannot be passthrough. Instead we subscribe to the shared keyframe
    // encoder, which re-encodes the decoded picture with a keyframe every second, and record that.
    /// Set by the host view (`DecodeSession.reencodeHub`).
    var keyframeHub: ReencodeHub?
    private var usingHub = false
    private var hubRelay: HubRelay?

    /// Forwards the hub's samples into the recorder; the raw stream is ignored while this is active.
    private final class HubRelay: SampleBufferRendering {
        weak var recorder: Recorder?
        func enqueue(_ sampleBuffer: CMSampleBuffer) { recorder?.process(sampleBuffer, fromHub: true) }
        func flush() {}
    }

    /// Shifts a timestamp so the recording starts at 0.
    static func normalized(_ time: CMTime, relativeTo start: CMTime) -> CMTime {
        CMTimeSubtract(time, start)
    }

    /// True only if the sample's AVCC data contains an IDR slice (diagnostics).
    static func hasIDR(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let ptr else { return false }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length)
        return containsIDR(avcc: bytes) == true
    }

    /// A sample is a keyframe if it is not flagged `NotSync` AND its AVCC data
    /// does not show only non-IDR slices. Live samples never carry a NotSync
    /// flag, so the NAL types are what actually tell IDR from P frames.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = arr.first,
           (first[kCMSampleAttachmentKey_NotSync] as? Bool) == true { return false }
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
               let ptr {
                let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length)
                if let idr = containsIDR(avcc: bytes) { return idr }
            }
        }
        return true
    }

    /// Scans 4-byte-length-prefixed NALs: true if any is an IDR slice (type 5),
    /// false if slices were seen but none is IDR, nil if nothing decidable.
    static func containsIDR<C: Collection>(avcc: C) -> Bool? where C.Element == UInt8, C.Index == Int {
        var i = avcc.startIndex
        var sawSlice = false
        while i + 4 < avcc.endIndex {
            let len = (Int(avcc[i]) << 24) | (Int(avcc[i + 1]) << 16) | (Int(avcc[i + 2]) << 8) | Int(avcc[i + 3])
            let h = i + 4
            guard len > 0, h < avcc.endIndex else { break }
            switch avcc[h] & 0x1F {
            case 5: return true
            case 1: sawSlice = true
            default: break
            }
            i = h + len
        }
        return sawSlice ? false : nil
    }

    // MARK: - Control

    /// Arms the recorder; the file is actually created at the next keyframe.
    /// Throws a `RecorderError` with a plain-language message when the folder is unusable or nearly full.
    func start(to url: URL = Recorder.defaultURL()) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.folderUnavailable(folder: folder, underlying: error)
        }
        if let free = capacityProvider(folder), free < Recorder.minFreeBytes {
            throw RecorderError.notEnoughSpace(folder: folder, freeBytes: free)
        }
        lock.lock()
        guard !armed else { lock.unlock(); return }
        self.url = url
        baseURL = url; part = 1; limits = limitsProvider()
        sessionStart = nil; segmentBytes = 0; sessionElapsed = 0; finished = []; pendingMarkers = []
        armed = true
        usingHub = false
        pendingHubSwitch = false; splitDueSince = nil
        consecutiveDrops = 0; totalDrops = 0; lastDropAt = .distantPast; lastDropPublish = .distantPast
        diskNoteShown = false
        lastSpaceCheck = now()
        var relayToSubscribe: (ReencodeHub, HubRelay)?
        if let hub = keyframeHub, OutputProcessor.needsReencodedStream {
            // Output crop, look and stabilizer only exist in the re-encoded stream, so record that from the start.
            usingHub = true
            let relay = HubRelay(); relay.recorder = self; hubRelay = relay
            relayToSubscribe = (hub, relay)
        }
        framesSeenWhileArmed = 0
        armedAt = now()
        Logging.recorder.info("armed, waiting for a start frame: \(url.lastPathComponent, privacy: .public)")
        startTime = nil; lastPTS = nil
        lock.unlock()
        ClipMetadataStore.writeRecordInfo(metadataProvider?(), for: url)
        if let (hub, relay) = relayToSubscribe { DispatchQueue.main.async { hub.subscribe(relay) } }
        DispatchQueue.main.async {
            self.lastError = nil; self.failure = nil; self.autoStop = nil; self.diskNote = nil
            self.elapsed = 0; self.markers = []; self.isRecording = true
        }
    }

    /// Everything `stop`, `fail` and the low-space stop take out of the recorder. Caller holds `lock`.
    private struct Teardown {
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var url: URL?
        var base: URL?
        var markers: [RecordingMarker]
        var relay: HubRelay?
        var wasArmed: Bool
    }

    private func teardownLocked() -> Teardown {
        let t = Teardown(writer: writer, input: input, url: url, base: baseURL, markers: pendingMarkers,
                         relay: hubRelay, wasArmed: armed)
        writer = nil; input = nil; url = nil; baseURL = nil; armed = false; startTime = nil; lastPTS = nil
        sessionStart = nil; pendingMarkers = []
        hubRelay = nil; usingHub = false; pendingHubSwitch = false; splitDueSince = nil
        return t
    }

    private func releaseRelay(_ relay: HubRelay?) {
        guard let relay, let hub = keyframeHub else { return }
        DispatchQueue.main.async { hub.unsubscribe(relay) }
    }

    /// Finalizes the file; `completion` gets the URL, or nil if nothing usable was written.
    func stop(completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        let t = teardownLocked()
        lock.unlock()
        if let relay = t.relay { keyframeHub?.unsubscribe(relay) }
        guard t.wasArmed else { completion?(nil); return }
        if let base = t.base, !t.markers.isEmpty { Recorder.writeMarkers(t.markers, for: base) }
        DispatchQueue.main.async { self.isRecording = false }
        finish(t, completion: completion)
    }

    /// Finishes the writer and reports problems. A file that no longer exists (deleted folder, unplugged
    /// drive) is reported as a failure instead of a success with a dead URL.
    private func finish(_ t: Teardown, completion: ((URL?) -> Void)?) {
        let folder = (t.base ?? t.url)?.deletingLastPathComponent() ?? RecordingPrefs.directory
        guard let w = t.writer else { completion?(nil); return }
        if w.status == .failed {
            publishFailure(error: w.error, folder: folder)
            completion?(nil)
            return
        }
        guard w.status == .writing else { completion?(nil); return }
        t.input?.markAsFinished()
        w.finishWriting { [self] in
            guard w.status == .completed else {
                publishFailure(error: w.error, folder: folder)
                completion?(nil)
                return
            }
            if let u = t.url, !FileManager.default.fileExists(atPath: u.path) {
                publishFailure(message: RecordingProblem.fileMissingMessage(folder: folder), folder: folder)
                completion?(nil)
                return
            }
            completion?(t.url)
        }
    }

    private func publishFailure(error: Error?, folder: URL, plain: String? = nil) {
        publishFailure(message: plain ?? RecordingProblem.plainMessage(error: error, folder: folder), folder: folder)
    }

    private func publishFailure(message: String, folder: URL) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.lastError = message
            self.failure = RecordingFailure(message: message, folder: folder)
        }
    }

    // MARK: - SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) { process(sampleBuffer, fromHub: false) }

    /// Entry point for samples from the re-encoded stream (also used by tests).
    func enqueueFromHub(_ sampleBuffer: CMSampleBuffer) { process(sampleBuffer, fromHub: true) }

    private func process(_ sampleBuffer: CMSampleBuffer, fromHub: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return }
        let clock = now()
        let keyframe = Recorder.isKeyframe(sampleBuffer)
        if fromHub != usingHub {
            // A requested switch to the re-encoded stream completes on its first keyframe: close the
            // current segment and let this keyframe open the next one.
            guard fromHub, pendingHubSwitch, let w = writer, keyframe else { return }
            Logging.recorder.info("switching to the re-encoded stream")
            rotate(finishing: w)
            usingHub = true; pendingHubSwitch = false
        }
        if writer == nil { framesSeenWhileArmed += 1; if framesSeenWhileArmed == 1 || framesSeenWhileArmed % 120 == 0 { Logging.recorder.info("frames seen while waiting: \(self.framesSeenWhileArmed), keyframe=\(keyframe)") } }

        if writer != nil {
            checkFreeSpace(clock)
            guard armed else { return }
        }

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let w = writer, let start = startTime {
            let due = RecordingExtras.shouldSplit(
                elapsed: CMTimeGetSeconds(Recorder.normalized(samplePTS, relativeTo: start)),
                bytes: segmentBytes, limits: limits)
            if due {
                if keyframe {
                    rotate(finishing: w)
                } else if !usingHub, !pendingHubSwitch, keyframeHub != nil {
                    // A raw goggles stream has a single IDR, so it never offers a clean cut point. After a
                    // short wait, switch to the re-encoded stream and rotate on its next keyframe.
                    if let since = splitDueSince {
                        if clock.timeIntervalSince(since) >= Recorder.splitKeyframeWait { beginHubSwitch() }
                    } else { splitDueSince = clock }
                }
            } else { splitDueSince = nil }
        }

        if writer == nil {
            // The goggles send one IDR at stream start and none after, so a recording armed mid-stream
            // would wait forever: after `keyframeWait` start on the next frame regardless.
            let waited = armedAt.map { clock.timeIntervalSince($0) } ?? 0
            if !keyframe {
                if !fromHub, waited >= Recorder.keyframeWait, keyframeHub != nil {
                    usingHub = true
                    Logging.recorder.info("no IDR from the goggles: recording the re-encoded stream instead")
                    subscribeRelay()
                }
                return
            }
            guard let url, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
                w.movieFragmentInterval = Recorder.fragmentInterval
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                inp.expectsMediaDataInRealTime = true
                guard w.canAdd(inp) else {
                    return fail("cannot add video input", plain: RecordingProblem.unsupportedFormatMessage)
                }
                w.add(inp)
                guard w.startWriting() else {
                    return fail(w.error?.localizedDescription ?? "startWriting failed", error: w.error)
                }
                w.startSession(atSourceTime: .zero)
                writer = w; input = inp
                Logging.recorder.info("writer started after \(self.framesSeenWhileArmed) frames, idr=\(Recorder.hasIDR(sampleBuffer))")
                startTime = samplePTS
                lastPTS = nil; segmentBytes = 0; splitDueSince = nil
                if sessionStart == nil { sessionStart = samplePTS }
            } catch {
                return fail(error.localizedDescription, error: error)
            }
        }

        guard let writer, let input, let start = startTime else { return }
        if writer.status == .failed { return fail(writer.error?.localizedDescription ?? "writer failed", error: writer.error) }
        guard readinessOverride?() ?? input.isReadyForMoreMediaData else { return noteDroppedFrame(clock, fromHub: fromHub) }
        consecutiveDrops = 0

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: .invalid, count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for k in timing.indices {
            var pts = Recorder.normalized(timing[k].presentationTimeStamp, relativeTo: start)
            // Frames arriving in a burst share a timestamp; keep PTS strictly increasing.
            if let last = lastPTS, pts <= last + Recorder.minFrameSpacing { pts = last + Recorder.minFrameSpacing }
            lastPTS = pts
            timing[k].presentationTimeStamp = pts
            if timing[k].decodeTimeStamp.isValid {
                timing[k].decodeTimeStamp = Recorder.normalized(timing[k].decodeTimeStamp, relativeTo: start)
            }
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                              sampleBufferOut: &retimed)
        guard let retimed else { return }
        if input.append(retimed) {
            segmentBytes += Int64(CMSampleBufferGetTotalSampleSize(sampleBuffer))
            let secs = max(0, CMTimeGetSeconds(CMTimeSubtract(samplePTS, sessionStart ?? start)))
            sessionElapsed = secs
            let clearNote = diskNoteShown && clock.timeIntervalSince(lastDropAt) > 5
            if clearNote { diskNoteShown = false }
            DispatchQueue.main.async {
                self.elapsed = secs
                if clearNote { self.diskNote = nil }
            }
        } else {
            fail(writer.error?.localizedDescription ?? "append failed", error: writer.error)
        }
    }

    func flush() {}

    private var diskNoteShown = false

    /// Counts a frame the writer could not take. A passthrough file loses its P-frames this way and
    /// stays corrupt until the next keyframe (the goggles send only one), so after a few drops in a
    /// row the recording continues from the re-encoded stream, which has a keyframe every second.
    private func noteDroppedFrame(_ clock: Date, fromHub: Bool) {
        totalDrops += 1; consecutiveDrops += 1; lastDropAt = clock
        if clock.timeIntervalSince(lastDropPublish) >= 1 {
            lastDropPublish = clock
            diskNoteShown = true
            let text = RecordingProblem.slowDiskNote(dropped: totalDrops)
            DispatchQueue.main.async { self.diskNote = text }
        }
        if !fromHub, !usingHub, !pendingHubSwitch, consecutiveDrops > Recorder.slowDiskDropThreshold, keyframeHub != nil {
            Logging.recorder.error("disk is slow: switching to the re-encoded stream after \(self.consecutiveDrops) dropped frames")
            beginHubSwitch()
        }
    }

    /// Subscribes to the re-encoded stream. Samples from it are accepted once `usingHub` is true, or,
    /// for a switch in progress, once its first keyframe arrives. Caller holds `lock`.
    private func beginHubSwitch() {
        pendingHubSwitch = true
        splitDueSince = nil
        subscribeRelay()
    }

    private func subscribeRelay() {
        guard hubRelay == nil, let hub = keyframeHub else { return }
        let relay = HubRelay(); relay.recorder = self; hubRelay = relay
        DispatchQueue.main.async { hub.subscribe(relay) }
    }

    /// Every `spaceCheckInterval`: if the folder vanished fail clearly, and if the disk is nearly full
    /// finish the file cleanly and tell the user. Caller holds `lock`.
    private func checkFreeSpace(_ clock: Date) {
        guard clock.timeIntervalSince(lastSpaceCheck) >= Recorder.spaceCheckInterval,
              let folder = baseURL?.deletingLastPathComponent() else { return }
        lastSpaceCheck = clock
        if !FileManager.default.fileExists(atPath: folder.path) {
            return fail("folder missing", plain: RecordingProblem.folderMissingMessage(folder: folder))
        }
        guard let free = capacityProvider(folder), free < Recorder.minFreeBytes else { return }
        Logging.recorder.error("only \(free) bytes free: finishing the recording")
        let t = teardownLocked()
        releaseRelay(t.relay)
        if let base = t.base, !t.markers.isEmpty { Recorder.writeMarkers(t.markers, for: base) }
        let message = RecordingProblem.lowSpaceStopMessage(folder: folder)
        DispatchQueue.main.async { self.isRecording = false }
        finish(t) { [self] url in
            DispatchQueue.main.async { self.autoStop = RecordingAutoStop(message: message, url: url) }
        }
    }

    /// Finalizes the current segment and points `url` at the next part; the same
    /// keyframe then opens the new file in `enqueue`. Caller holds `lock`.
    private func rotate(finishing w: AVAssetWriter) {
        let done = url, duration = lastPTS.map { CMTimeGetSeconds($0) } ?? 0
        input?.markAsFinished()
        writer = nil; input = nil; startTime = nil; lastPTS = nil; splitDueSince = nil
        if let done { finished.append((done, duration)) }
        part += 1
        if let baseURL { url = RecordingExtras.partURL(base: baseURL, part: part) }
        w.finishWriting { [weak self] in
            guard let self else { return }
            let ok = w.status == .completed
            if !ok {
                DispatchQueue.main.async { self.lastError = w.error?.localizedDescription }
            }
            // Loop mode: only ever delete once the segment that just rotated was finalised, so a failed
            // write never costs the user older footage. Only files this session created are in `finished`.
            self.lock.lock()
            if !ok, let done { self.finished.removeAll { $0.url == done } }
            var doomed: [URL] = []
            if let keep = self.limits.loopKeepSeconds {
                doomed = RecordingExtras.loopDeletions(finished: self.finished, keepSeconds: keep, lastSegmentCompleted: ok)
                self.finished.removeFirst(doomed.count)
            }
            self.lock.unlock()
            for u in doomed { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: - Markers

    /// Adds a marker at the current recording time (no-op when not recording).
    func addMarker(label: String) {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard armed, let base = baseURL, !text.isEmpty else { lock.unlock(); return }
        pendingMarkers.append(RecordingMarker(t: (sessionElapsed * 1000).rounded() / 1000, label: text))
        let all = pendingMarkers
        lock.unlock()
        Recorder.writeMarkers(all, for: base)
        DispatchQueue.main.async {
            self.markers = all
            NotificationCenter.default.post(name: .gogglesMarkerAdded, object: nil, userInfo: ["label": text])
        }
    }

    private static func writeMarkers(_ marks: [RecordingMarker], for recording: URL) {
        guard let data = RecordingMarkers.encode(marks) else { return }
        try? data.write(to: RecordingMarkers.sidecarURL(for: recording), options: .atomic)
    }

    /// Stops the recording once (later calls do nothing, so a failed writer can't spam the log at 60 fps),
    /// keeps whatever was written, and tells the user in plain words. Caller holds `lock`.
    private func fail(_ message: String, error: Error? = nil, plain: String? = nil) {
        guard armed else { return }
        let err = error ?? writer?.error
        let ns = err as NSError?
        let detail = ns.map { " [\($0.domain) \($0.code) underlying=\(String(describing: $0.userInfo[NSUnderlyingErrorKey]))]" } ?? ""
        Logging.recorder.error("recording failed: \(message, privacy: .public)\(detail, privacy: .public)")
        let t = teardownLocked()
        releaseRelay(t.relay)
        if let base = t.base, !t.markers.isEmpty { Recorder.writeMarkers(t.markers, for: base) }
        // A failed writer is left alone (cancelling would delete the partial file, which is still playable
        // up to the last movie fragment); a healthy one is finished.
        if let w = t.writer, w.status == .writing {
            t.input?.markAsFinished()
            w.finishWriting {}
        }
        let folder = (t.base ?? t.url)?.deletingLastPathComponent() ?? RecordingPrefs.directory
        publishFailure(error: err, folder: folder, plain: plain)
    }
}

/// A recording that failed and was stopped.
struct RecordingFailure: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let folder: URL
}

/// A recording the recorder finished on its own, with the reason.
struct RecordingAutoStop: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let url: URL?
}

/// Why `Recorder.start` refused to arm.
enum RecorderError: LocalizedError {
    case notEnoughSpace(folder: URL, freeBytes: Int64)
    case folderUnavailable(folder: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let folder, _): return RecordingProblem.notEnoughSpaceMessage(folder: folder)
        case .folderUnavailable(let folder, let e): return RecordingProblem.plainMessage(error: e, folder: folder)
        }
    }
}

/// Plain-language wording for recording problems (unit-tested).
enum RecordingProblem {
    static let unsupportedFormatMessage = "This stream can't be recorded in the chosen format. Try .mov in Settings > Recording."

    static func folderName(_ folder: URL) -> String { folder.lastPathComponent }

    static func genericMessage(folder: URL) -> String {
        "Recording couldn't be saved. Check that the folder '\(folderName(folder))' exists and has free space, then try again."
    }
    static func notEnoughSpaceMessage(folder: URL) -> String {
        "There isn't enough free space to record (less than 500 MB left in '\(folderName(folder))'). Free up space or choose another folder in Settings > Recording."
    }
    static func diskFullMessage(folder: URL) -> String {
        "Recording stopped because the disk is full. Free up space or choose another folder in Settings > Recording."
    }
    static func folderMissingMessage(folder: URL) -> String {
        "Recording couldn't be saved because the folder '\(folderName(folder))' is missing. Choose another folder in Settings > Recording."
    }
    static func notWritableMessage(folder: URL) -> String {
        "Recording couldn't be saved because GogglesView can't write to the folder '\(folderName(folder))'. Choose another folder in Settings > Recording."
    }
    static func fileMissingMessage(folder: URL) -> String {
        "The recording file is gone. The folder '\(folderName(folder))' may have been deleted or the drive unplugged."
    }
    static func lowSpaceStopMessage(folder: URL) -> String {
        "Recording stopped and was saved because the disk is almost full (less than 500 MB left)."
    }
    static func slowDiskNote(dropped: Int) -> String {
        "Disk is slow, \(dropped) frame\(dropped == 1 ? "" : "s") dropped"
    }

    private enum Cause { case diskFull, folderMissing, notWritable }

    /// Looks through the error and its underlying errors for a cause we can name.
    private static func cause(of error: Error?) -> Cause? {
        var current = error as NSError?
        var depth = 0
        while let e = current, depth < 6 {
            switch (e.domain, e.code) {
            case (NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28), (AVFoundationErrorDomain, -11807):
                return .diskFull
            case (NSCocoaErrorDomain, 4), (NSCocoaErrorDomain, 260), (NSPOSIXErrorDomain, 2):
                return .folderMissing
            case (NSCocoaErrorDomain, 513), (NSCocoaErrorDomain, 642), (NSCocoaErrorDomain, 257),
                 (NSPOSIXErrorDomain, 13), (NSPOSIXErrorDomain, 1), (NSPOSIXErrorDomain, 30):
                return .notWritable
            default: break
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    static func plainMessage(error: Error?, folder: URL,
                             folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
        if !folderExists(folder) { return folderMissingMessage(folder: folder) }
        switch cause(of: error) {
        case .diskFull: return diskFullMessage(folder: folder)
        case .folderMissing: return folderMissingMessage(folder: folder)
        case .notWritable: return notWritableMessage(folder: folder)
        case nil: return genericMessage(folder: folder)
        }
    }
}

/// Alert shown when a recording can't start or had to stop.
enum RecordingAlerts {
    static func presentFailure(_ message: String, onOpenSettings: (() -> Void)?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording problem"
        alert.informativeText = message
        if onOpenSettings != nil { alert.addButton(withTitle: "Open Settings") }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn, onOpenSettings != nil {
            UserDefaults.standard.set("Recording", forKey: "settingsTab")
            onOpenSettings?()
        }
    }
}

/// User-configurable recording options, persisted in UserDefaults.
enum RecordingPrefs {
    static let folderKey = "recordingFolder"
    static let containerKey = "recordingContainer"
    static let prefixKey = "recordingPrefix"
    static let autoStartKey = "recordingAutoStart"

    enum Container: String, CaseIterable, Identifiable {
        case mov, mp4
        var id: String { rawValue }
        var ext: String { rawValue }
    }

    static var directory: URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return Recorder.defaultDirectory
    }

    static var container: Container {
        Container(rawValue: UserDefaults.standard.string(forKey: containerKey) ?? "") ?? .mov
    }

    static var prefix: String {
        let raw = UserDefaults.standard.string(forKey: prefixKey) ?? ""
        let cleaned = raw.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "GogglesView" : cleaned
    }

    /// Opens the recordings folder in Finder, creating it first if needed.
    static func openFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    static var autoStart: Bool { UserDefaults.standard.bool(forKey: autoStartKey) }
}
