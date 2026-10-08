import AVFoundation
import CoreMedia
import Foundation

enum ReplayPrefs {
    static let enabledKey = "replayEnabled"
    static let secondsKey = "replaySeconds"
    static let secondsRange = 10...120

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var seconds: Int {
        guard UserDefaults.standard.object(forKey: secondsKey) != nil else { return 30 }
        return min(max(UserDefaults.standard.integer(forKey: secondsKey), secondsRange.lowerBound), secondsRange.upperBound)
    }

    /// Replay needs a keyframe every second, which only the re-encoded stream has: the raw goggles stream
    /// has a single keyframe at the start, so a buffer cut from it would never be playable.
    static var isAvailable: Bool { isAvailable(reencode: ReencodePrefs.enabled, outputActive: OutputProcessor.isActive) }
    static func isAvailable(reencode: Bool, outputActive: Bool) -> Bool { reencode || outputActive }

    static var unavailableMessage: String { L("Instant replay needs the keyframe encoder. Turn it on in Settings > Streaming.") }
    static var offMessage: String { L("Instant replay is off. Turn it on in Settings > Recording.") }

    /// Why a "save replay" request cannot work right now, or nil when it can.
    static func blockedMessage(enabled: Bool, reencode: Bool, outputActive: Bool) -> String? {
        if !enabled { return offMessage }
        if !isAvailable(reencode: reencode, outputActive: outputActive) { return unavailableMessage }
        return nil
    }
    static var currentBlockedMessage: String? {
        blockedMessage(enabled: enabled, reencode: ReencodePrefs.enabled, outputActive: OutputProcessor.isActive)
    }

    /// The window the memory cap really allows at a given bitrate (the buffer holds at most `byteCap` bytes).
    static func achievableSeconds(requested: Int, bitrateMbps: Int, byteCap: Int = ReplayBuffer.byteCap) -> Int {
        guard bitrateMbps > 0 else { return requested }
        let limit = Int(Double(byteCap) * 8 / (Double(bitrateMbps) * 1_000_000))
        return min(requested, limit)
    }
}

/// Pure rolling-window logic, generic so it can be tested without real sample buffers.
/// Invariant: the window always begins at a keyframe.
struct ReplayWindow<Item> {
    struct Entry { var item: Item; var pts: Double; var bytes: Int; var isKey: Bool }
    private(set) var entries: [Entry] = []
    private(set) var totalBytes = 0
    var maxSeconds: Double
    var maxBytes: Int

    init(maxSeconds: Double, maxBytes: Int) { self.maxSeconds = maxSeconds; self.maxBytes = maxBytes }

    var duration: Double { entries.count > 1 ? entries[entries.count - 1].pts - entries[0].pts : 0 }

    mutating func append(_ item: Item, pts: Double, bytes: Int, isKey: Bool) {
        if entries.isEmpty && !isKey { return }
        entries.append(Entry(item: item, pts: pts, bytes: bytes, isKey: isKey))
        totalBytes += bytes
        trim()
    }

    mutating func removeAll() { entries.removeAll(); totalBytes = 0 }

    mutating func trim() {
        guard let last = entries.last else { return }
        // Drop the oldest group while the next keyframe still leaves >= maxSeconds.
        while let next = nextKeyIndex(), entries[next].pts <= last.pts - maxSeconds { drop(next) }
        // Byte cap: drop whole oldest groups while a later keyframe exists. The only group left is never
        // discarded (that would empty the buffer for good); it may overshoot the cap until the next
        // keyframe lets the older part go. Past twice the cap, with no keyframe in sight, start over
        // at the next keyframe instead of growing without bound.
        while totalBytes > maxBytes, let next = nextKeyIndex() { drop(next) }
        if maxBytes <= Int.max / 2, totalBytes > maxBytes * 2 { removeAll() }
    }

    private func nextKeyIndex() -> Int? { entries.indices.dropFirst().first { entries[$0].isKey } }
    private mutating func drop(_ n: Int) {
        totalBytes -= entries[..<n].reduce(0) { $0 + $1.bytes }
        entries.removeFirst(n)
    }
}

/// Rolling in-memory window of the last N seconds of passthrough H.264, savable to a file.
final class ReplayBuffer: ObservableObject, SampleBufferRendering {
    static let byteCap = 256 * 1024 * 1024

    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var lastError: String?

    private let lock = NSLock()
    private var window: ReplayWindow<CMSampleBuffer>
    private var lastPublish = Date.distantPast

    init(seconds: Int = ReplayPrefs.seconds, byteCap: Int = ReplayBuffer.byteCap) {
        window = ReplayWindow(maxSeconds: Double(seconds), maxBytes: byteCap)
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current, prefix: String, ext: String) -> String {
        Recorder.fileName(for: date, timeZone: timeZone, prefix: "\(prefix)-replay", ext: ext)
    }

    func setSeconds(_ s: Int) {
        lock.lock(); window.maxSeconds = Double(s); window.trim(); lock.unlock()
    }

    func clear() {
        lock.lock(); window.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.bufferedSeconds = 0 }
    }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let bytes = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        lock.lock()
        window.append(sampleBuffer, pts: pts, bytes: bytes, isKey: Recorder.isKeyframe(sampleBuffer))
        let d = window.duration
        let publish = Date().timeIntervalSince(lastPublish) > 0.5
        if publish { lastPublish = Date() }
        lock.unlock()
        if publish { DispatchQueue.main.async { self.bufferedSeconds = d } }
    }

    func flush() { clear() }

    // MARK: Save

    func save(completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        let samples = window.entries.map(\.item)
        lock.unlock()
        let url = UniqueFileURL.reserve(RecordingPrefs.directory.appendingPathComponent(
            Self.fileName(for: Date(), prefix: RecordingPrefs.prefix, ext: RecordingPrefs.container.ext)))
        func done(_ u: URL?, _ err: String?) {
            DispatchQueue.main.async {
                if let u { self.lastSavedURL = u; self.lastError = nil } else { self.lastError = err ?? L("save failed") }
                completion?(u)
            }
        }
        guard let first = samples.first, let fmt = CMSampleBufferGetFormatDescription(first) else {
            return done(nil, L("Replay buffer is empty"))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            inp.expectsMediaDataInRealTime = false
            guard w.canAdd(inp) else { return done(nil, "cannot add video input") }
            w.add(inp)
            guard w.startWriting() else { return done(nil, w.error?.localizedDescription ?? "startWriting failed") }
            w.startSession(atSourceTime: .zero)
            let start = CMSampleBufferGetPresentationTimeStamp(first)
            var idx = 0
            let q = DispatchQueue(label: "replay.save")
            inp.requestMediaDataWhenReady(on: q) {
                while inp.isReadyForMoreMediaData {
                    guard idx < samples.count else {
                        inp.markAsFinished()
                        w.finishWriting {
                            done(w.status == .completed ? url : nil, w.error?.localizedDescription)
                        }
                        return
                    }
                    guard let s = Self.retimed(samples[idx], start: start), inp.append(s) else {
                        inp.markAsFinished()
                        let msg = w.error?.localizedDescription ?? "append failed"
                        w.cancelWriting()
                        return done(nil, msg)
                    }
                    idx += 1
                }
            }
        } catch {
            done(nil, error.localizedDescription)
        }
    }

    private static func retimed(_ sb: CMSampleBuffer, start: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: .invalid, count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for k in timing.indices {
            timing[k].presentationTimeStamp = Recorder.normalized(timing[k].presentationTimeStamp, relativeTo: start)
            if timing[k].decodeTimeStamp.isValid {
                timing[k].decodeTimeStamp = Recorder.normalized(timing[k].decodeTimeStamp, relativeTo: start)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
