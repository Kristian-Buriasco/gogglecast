import AVFoundation
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

    private let lock = NSLock()
    private var url: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private var armed = false

    // MARK: - Pure helpers (unit-tested)

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

    /// Shifts a timestamp so the recording starts at 0.
    static func normalized(_ time: CMTime, relativeTo start: CMTime) -> CMTime {
        CMTimeSubtract(time, start)
    }

    /// A sample is a keyframe unless it carries `NotSync = true`.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = arr.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    // MARK: - Control

    /// Arms the recorder; the file is actually created at the next keyframe.
    func start(to url: URL = Recorder.defaultURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.lock()
        guard !armed else { lock.unlock(); return }
        self.url = url
        armed = true
        startTime = nil
        lock.unlock()
        DispatchQueue.main.async { self.lastError = nil; self.elapsed = 0; self.isRecording = true }
    }

    /// Finalizes the file; `completion` gets the URL, or nil if nothing was written.
    func stop(completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        let w = writer, i = input, u = url
        let wasArmed = armed
        writer = nil; input = nil; url = nil; armed = false; startTime = nil
        lock.unlock()
        guard wasArmed else { completion?(nil); return }
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

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return }

        if writer == nil {
            guard Recorder.isKeyframe(sampleBuffer), let url,
                  let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
                inp.expectsMediaDataInRealTime = true
                guard w.canAdd(inp) else { return fail("cannot add video input") }
                w.add(inp)
                guard w.startWriting() else { return fail(w.error?.localizedDescription ?? "startWriting failed") }
                w.startSession(atSourceTime: .zero)
                writer = w; input = inp
                startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
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
            timing[k].presentationTimeStamp = Recorder.normalized(timing[k].presentationTimeStamp, relativeTo: start)
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
            let secs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(retimed))
            DispatchQueue.main.async { self.elapsed = max(0, secs) }
        } else {
            fail(writer.error?.localizedDescription ?? "append failed")
        }
    }

    func flush() {}

    private func fail(_ message: String) {
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

    static var autoStart: Bool { UserDefaults.standard.bool(forKey: autoStartKey) }
}
