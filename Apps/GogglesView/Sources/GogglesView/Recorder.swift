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

    init() { RecordingExtras.runLaunchCleanupOnce() }

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
    func start(to url: URL = Recorder.defaultURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.lock()
        guard !armed else { lock.unlock(); return }
        self.url = url
        baseURL = url; part = 1; limits = RecordingExtras.currentLimits()
        sessionStart = nil; segmentBytes = 0; sessionElapsed = 0; finished = []; pendingMarkers = []
        armed = true
        usingHub = false
        var relayToSubscribe: (ReencodeHub, HubRelay)?
        if let hub = keyframeHub, OutputProcessor.isActive {
            // Output crop / look only exist in the re-encoded stream, so record that from the start.
            usingHub = true
            let relay = HubRelay(); relay.recorder = self; hubRelay = relay
            relayToSubscribe = (hub, relay)
        }
        framesSeenWhileArmed = 0
        armedAt = Date()
        Logging.recorder.info("armed, waiting for a start frame: \(url.lastPathComponent, privacy: .public)")
        startTime = nil; lastPTS = nil
        lock.unlock()
        if let (hub, relay) = relayToSubscribe { DispatchQueue.main.async { hub.subscribe(relay) } }
        DispatchQueue.main.async { self.lastError = nil; self.elapsed = 0; self.markers = []; self.isRecording = true }
    }

    /// Finalizes the file; `completion` gets the URL, or nil if nothing was written.
    func stop(completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        let w = writer, i = input, u = url
        let wasArmed = armed
        let base = baseURL, marks = pendingMarkers
        writer = nil; input = nil; url = nil; baseURL = nil; armed = false; startTime = nil; lastPTS = nil
        sessionStart = nil; pendingMarkers = []
        let relay = hubRelay; hubRelay = nil; usingHub = false
        lock.unlock()
        if let relay { keyframeHub?.unsubscribe(relay) }
        guard wasArmed else { completion?(nil); return }
        if let base, !marks.isEmpty { Recorder.writeMarkers(marks, for: base) }
        DispatchQueue.main.async { self.isRecording = false }
        guard let w, w.status == .writing else { completion?(nil); return }
        i?.markAsFinished()
        w.finishWriting {
            if w.status != .completed {
                DispatchQueue.main.async { self.lastError = w.error?.localizedDescription }
            }
            completion?(w.status == .completed ? u : nil)
        }
    }

    // MARK: - SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) { process(sampleBuffer, fromHub: false) }

    private func process(_ sampleBuffer: CMSampleBuffer, fromHub: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard armed, fromHub == usingHub else { return }
        if writer == nil { framesSeenWhileArmed += 1; if framesSeenWhileArmed == 1 || framesSeenWhileArmed % 120 == 0 { Logging.recorder.info("frames seen while waiting: \(self.framesSeenWhileArmed), keyframe=\(Recorder.isKeyframe(sampleBuffer))") } }

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let w = writer, let start = startTime, Recorder.isKeyframe(sampleBuffer),
           RecordingExtras.shouldSplit(
               elapsed: CMTimeGetSeconds(Recorder.normalized(samplePTS, relativeTo: start)),
               bytes: segmentBytes, limits: limits) {
            rotate(finishing: w)
        }

        if writer == nil {
            // The goggles send one IDR at stream start and none after, so a recording armed mid-stream
            // would wait forever: after `keyframeWait` start on the next frame regardless.
            let waited = armedAt.map { Date().timeIntervalSince($0) } ?? 0
            if !Recorder.isKeyframe(sampleBuffer) {
                if !fromHub, waited >= Recorder.keyframeWait, let hub = keyframeHub {
                    usingHub = true
                    let relay = HubRelay(); relay.recorder = self; hubRelay = relay
                    Logging.recorder.info("no IDR from the goggles: recording the re-encoded stream instead")
                    DispatchQueue.main.async { hub.subscribe(relay) }
                }
                return
            }
            guard let url, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                inp.expectsMediaDataInRealTime = true
                guard w.canAdd(inp) else { return fail("cannot add video input") }
                w.add(inp)
                guard w.startWriting() else { return fail(w.error?.localizedDescription ?? "startWriting failed") }
                w.startSession(atSourceTime: .zero)
                writer = w; input = inp
                Logging.recorder.info("writer started after \(self.framesSeenWhileArmed) frames, idr=\(Recorder.hasIDR(sampleBuffer))")
                startTime = samplePTS
                lastPTS = nil; segmentBytes = 0
                if sessionStart == nil { sessionStart = samplePTS }
            } catch {
                return fail(error.localizedDescription)
            }
        }

        guard let writer, let input, let start = startTime else { return }
        if writer.status == .failed { return fail(writer.error?.localizedDescription ?? "writer failed") }
        guard input.isReadyForMoreMediaData else { return }

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
            DispatchQueue.main.async { self.elapsed = secs }
        } else {
            fail(writer.error?.localizedDescription ?? "append failed")
        }
    }

    func flush() {}

    /// Finalizes the current segment and points `url` at the next part; the same
    /// keyframe then opens the new file in `enqueue`. Caller holds `lock`.
    private func rotate(finishing w: AVAssetWriter) {
        let done = url, duration = lastPTS.map { CMTimeGetSeconds($0) } ?? 0
        input?.markAsFinished()
        writer = nil; input = nil; startTime = nil; lastPTS = nil
        if let done { finished.append((done, duration)) }
        part += 1
        if let baseURL { url = RecordingExtras.partURL(base: baseURL, part: part) }
        var doomed: [URL] = []
        if let keep = limits.loopKeepSeconds {
            let n = RecordingExtras.segmentsToDelete(durations: finished.map(\.duration), keepSeconds: keep)
            doomed = finished.prefix(n).map(\.url)
            finished.removeFirst(n)
        }
        w.finishWriting { [weak self] in
            if w.status != .completed {
                DispatchQueue.main.async { self?.lastError = w.error?.localizedDescription }
            }
            // Only files this session created are ever in `finished`.
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

    private func fail(_ message: String) {
        let detail = (writer?.error as NSError?).map { " [\($0.domain) \($0.code) underlying=\(String(describing: $0.userInfo[NSUnderlyingErrorKey]))]" } ?? ""
        Logging.recorder.error("recording failed: \(message, privacy: .public)\(detail, privacy: .public)")
        DispatchQueue.main.async { self.lastError = message }
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
