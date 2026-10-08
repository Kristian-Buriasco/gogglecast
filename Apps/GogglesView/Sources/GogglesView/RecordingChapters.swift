import AVFoundation
import CoreMedia
import Foundation

// Chapters in finished recordings.
//
// A chapter list is a timed-text track associated with the video track (`chap` track reference). It
// cannot be written while the recording runs: AVAssetWriter interleaves its inputs, and a text track
// that only gets a sample when the next marker arrives holds the video back (no movie fragment is
// closed past the last chapter sample, so a crash loses the video too, and a real-time video input
// stops being ready). So the recording itself stays video-only and crash-safe, and when it is
// finished a rewrite pass copies the compressed samples unchanged into a temporary file together
// with the chapter track, checks the result, and only then replaces the original. The
// `.markers.json` sidecar stays the source of truth and is written first.

/// Pure planning of chapter samples (unit-tested).
enum ChapterPlan {
    /// Chapters closer than this are pushed apart so every sample has a usable duration.
    static let minSpacing: TimeInterval = 0.1

    struct Entry: Equatable {
        var start: TimeInterval
        var duration: TimeInterval
        var title: String
    }

    /// Sorted, strictly increasing starts at least `minSpacing` apart, all inside `[0, duration)`; each
    /// chapter lasts until the next one starts and the last until `duration`. Chapters that no longer fit are dropped.
    static func entries(for chapters: [(start: TimeInterval, title: String)], duration: TimeInterval) -> [Entry] {
        guard duration > minSpacing else { return [] }
        var starts: [(start: TimeInterval, title: String)] = []
        for c in chapters.sorted(by: { $0.start < $1.start }) where c.start.isFinite {
            var s = max(0, c.start)
            if let last = starts.last { s = max(s, last.start + minSpacing) }
            starts.append((s, c.title))
        }
        // Pushing apart can move late chapters past the end: each needs room for its minimum duration.
        starts = starts.filter { $0.start + minSpacing <= duration + 1e-9 }
        return starts.enumerated().map { i, c in
            let end = i + 1 < starts.count ? starts[i + 1].start : duration
            return Entry(start: c.start, duration: end - c.start, title: c.title)
        }
    }
}

/// Builds the timed text track and rewrites finished recordings with it.
enum ChapterRewriter {
    static let timescale: CMTimeScale = 600
    /// Largest difference between the original's and the rewrite's duration that still counts as the same recording.
    static let durationTolerance: TimeInterval = 0.1

    /// A `tx3g` (3GPP timed text) format description with default styling. AVFoundation refuses the
    /// plain QuickTime `text` flavour without a full style block; `tx3g` is accepted in .mov and .mp4
    /// and is what chapter tracks in iTunes and ffmpeg files use.
    static func textFormatDescription() -> CMFormatDescription? {
        func color(_ v: Int8) -> [CFString: Any] {
            [kCMTextFormatDescriptionColor_Red: v, kCMTextFormatDescriptionColor_Green: v,
             kCMTextFormatDescriptionColor_Blue: v, kCMTextFormatDescriptionColor_Alpha: Int8(-1)]
        }
        let box: [CFString: Any] = [
            kCMTextFormatDescriptionRect_Top: Int16(0), kCMTextFormatDescriptionRect_Left: Int16(0),
            kCMTextFormatDescriptionRect_Bottom: Int16(0), kCMTextFormatDescriptionRect_Right: Int16(0),
        ]
        let style: [CFString: Any] = [
            kCMTextFormatDescriptionStyle_StartChar: Int16(0), kCMTextFormatDescriptionStyle_EndChar: Int16(0),
            kCMTextFormatDescriptionStyle_Font: Int16(1), kCMTextFormatDescriptionStyle_FontFace: Int8(0),
            kCMTextFormatDescriptionStyle_FontSize: Int8(18), kCMTextFormatDescriptionStyle_ForegroundColor: color(-1),
        ]
        let ext: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: Int32(0),
            kCMTextFormatDescriptionExtension_BackgroundColor: color(0),
            kCMTextFormatDescriptionExtension_HorizontalJustification: Int8(0),
            kCMTextFormatDescriptionExtension_VerticalJustification: Int8(-1),
            kCMTextFormatDescriptionExtension_DefaultTextBox: box,
            kCMTextFormatDescriptionExtension_DefaultStyle: style,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var fmt: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: ext as CFDictionary, formatDescriptionOut: &fmt)
        return status == noErr ? fmt : nil
    }

    /// One timed text sample: a big-endian 16-bit length followed by the UTF-8 text.
    static func sample(_ entry: ChapterPlan.Entry, format: CMFormatDescription) -> CMSampleBuffer? {
        let text = Array(entry.title.utf8.prefix(1000))
        let bytes: [UInt8] = [UInt8(text.count >> 8), UInt8(text.count & 0xFF)] + text
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: bytes.count) == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: entry.duration, preferredTimescale: timescale),
            presentationTimeStamp: CMTime(seconds: entry.start, preferredTimescale: timescale),
            decodeTimeStamp: .invalid)
        var size = bytes.count
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    enum Outcome: Equatable {
        case added(chapters: Int)
        case skipped(String)
        case failed(String)
    }

    /// Adds `chapters` (seconds from the start of the file) to the finished recording at `url`.
    /// Blocks until done, so call it off the main thread. The original is replaced only after the copy
    /// opens, has one video track, the same duration and a readable chapter list; on any problem it is
    /// left exactly as it was and the temporary file is removed.
    @discardableResult
    static func addChapters(_ chapters: [(start: TimeInterval, title: String)], to url: URL,
                            fileManager fm: FileManager = .default) -> Outcome {
        guard !chapters.isEmpty else { return .skipped("no markers") }
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let asset = AVURLAsset(url: url)
        guard let duration = loadSync({ try await asset.load(.duration) })?.seconds, duration.isFinite, duration > 0,
              let track = loadSync({ try await asset.loadTracks(withMediaType: .video).first }) ?? nil,
              let transform = loadSync({ try await track.load(.preferredTransform) }),
              let videoFormat = loadSync({ try await track.load(.formatDescriptions).first }) ?? nil
        else { return .skipped("the recording could not be read") }
        let entries = ChapterPlan.entries(for: chapters, duration: duration)
        guard !entries.isEmpty, let textFormat = textFormatDescription() else { return .skipped("no chapter fits") }

        // The copy needs about as much room as the original.
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if let free = Recorder.volumeCapacity(at: url.deletingLastPathComponent()), free < size + 200_000_000 {
            return .skipped("not enough free space for the chapter pass")
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent).chapters-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        defer { try? fm.removeItem(at: tmp) }
        if let problem = copy(asset: asset, track: track, transform: transform, videoFormat: videoFormat,
                              textFormat: textFormat, entries: entries, to: tmp, fileType: fileType, duration: duration) {
            return .failed(problem)
        }
        if let problem = verify(copy: tmp, expectedDuration: duration, expectedTitles: entries.map(\.title)) {
            return .failed(problem)
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            return .failed("replace failed: \(error.localizedDescription)")
        }
        return .added(chapters: entries.count)
    }

    /// Copies the compressed video samples unchanged and writes the chapter track. Returns a problem or nil.
    private static func copy(asset: AVURLAsset, track: AVAssetTrack, transform: CGAffineTransform,
                             videoFormat: CMFormatDescription, textFormat: CMFormatDescription,
                             entries: [ChapterPlan.Entry], to tmp: URL, fileType: AVFileType,
                             duration: TimeInterval) -> String? {
        do {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { return "cannot read the video track" }
            reader.add(out)

            let writer = try AVAssetWriter(outputURL: tmp, fileType: fileType)
            writer.movieFragmentInterval = Recorder.fragmentInterval
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            video.expectsMediaDataInRealTime = false
            video.transform = transform
            let text = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
            text.expectsMediaDataInRealTime = false
            guard writer.canAdd(video), writer.canAdd(text) else { return "cannot write the chapter track" }
            writer.add(video)
            writer.add(text)
            let chapterList = AVAssetTrack.AssociationType.chapterList.rawValue
            guard video.canAddTrackAssociation(withTrackOf: text, type: chapterList) else { return "chapter list not supported" }
            video.addTrackAssociation(withTrackOf: text, type: chapterList)
            guard reader.startReading() else { return "reader: \(reader.error?.localizedDescription ?? "failed")" }
            guard writer.startWriting() else { return "writer: \(writer.error?.localizedDescription ?? "failed")" }
            writer.startSession(atSourceTime: .zero)

            var samples: [CMSampleBuffer] = []
            for e in entries {
                guard let s = sample(e, format: textFormat) else { return "chapter sample failed" }
                samples.append(s)
            }
            // Both inputs are fed from callbacks: a non-real-time input is only ready when the writer wants its data.
            let textDone = DispatchSemaphore(value: 0)
            var next = 0
            text.requestMediaDataWhenReady(on: DispatchQueue(label: "chapter-rewrite-text")) {
                while text.isReadyForMoreMediaData {
                    if next >= samples.count { text.markAsFinished(); textDone.signal(); return }
                    if !text.append(samples[next]) { text.markAsFinished(); textDone.signal(); return }
                    next += 1
                }
            }

            let box = ResultBox<String>()
            let done = DispatchSemaphore(value: 0)
            video.requestMediaDataWhenReady(on: DispatchQueue(label: "chapter-rewrite")) {
                while video.isReadyForMoreMediaData {
                    guard let sample = out.copyNextSampleBuffer() else {
                        if reader.status == .failed { box.value = "reader: \(reader.error?.localizedDescription ?? "failed")" }
                        video.markAsFinished()
                        done.signal()
                        return
                    }
                    if !video.append(sample) {
                        box.value = "writer: \(writer.error?.localizedDescription ?? "append failed")"
                        reader.cancelReading()
                        video.markAsFinished()
                        done.signal()
                        return
                    }
                }
            }
            done.wait()
            textDone.wait()
            if let problem = box.value { writer.cancelWriting(); return problem }
            guard next == samples.count else { writer.cancelWriting(); return "chapter append: \(writer.error?.localizedDescription ?? "failed")" }
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: timescale))
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { return "writer: \(writer.error?.localizedDescription ?? "not completed")" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Opens the copy like a player would. Returns a problem, or nil when it is a faithful copy with chapters.
    static func verify(copy url: URL, expectedDuration: TimeInterval, expectedTitles: [String]) -> String? {
        let asset = AVURLAsset(url: url)
        guard loadSync({ try await asset.load(.isPlayable) }) == true else { return "copy is not playable" }
        guard let d = loadSync({ try await asset.load(.duration) })?.seconds, d.isFinite else { return "copy has no duration" }
        guard abs(d - expectedDuration) <= durationTolerance else { return "duration changed (\(d) s instead of \(expectedDuration) s)" }
        let videoTracks = loadSync({ try await asset.loadTracks(withMediaType: .video).count }) ?? 0
        guard videoTracks == 1 else { return "copy has \(videoTracks) video tracks" }
        let titles = chapterTitles(of: asset)
        guard titles == expectedTitles else { return "chapters read back as \(titles) instead of \(expectedTitles)" }
        return nil
    }

    /// Chapter titles as a player lists them. Off the main thread only.
    static func chapterTitles(of asset: AVAsset) -> [String] {
        chapters(of: asset).map(\.title)
    }

    /// Chapter titles with their start times. Off the main thread only.
    static func chapters(of asset: AVAsset) -> [(title: String, start: TimeInterval)] {
        guard let groups = loadSync({ try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en", "und"]) })
        else { return [] }
        return groups.map { g in
            let item = g.items.first { $0.commonKey == .commonKeyTitle }
            let title = loadSync({ try await item?.load(.stringValue) }).flatMap { $0 } ?? ""
            return (title, g.timeRange.start.seconds)
        }
    }

    /// Runs an async AVFoundation load to completion from a background (non-main, non-cooperative) thread.
    private static func loadSync<T>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await work()
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T? }
}
