import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import CoreText
import Foundation
import VideoToolbox

// Burn-in recording: decodes the live H.264 stream, composites a logo and
// optional stats text, and re-encodes to its own file. Independent of the
// passthrough `Recorder`; both can be registered as DecodeSession consumers.

/// Snapshot of stream stats supplied by the UI (keeps this file app-state free).
struct BurnInInfo: Equatable {
    var fps: Int?
    var bitrateKbps: Double?
    var resolution: String?
}

enum BurnInCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    /// Same vertical edge, other side: where the text goes so it doesn't sit on the logo.
    var mirroredHorizontally: BurnInCorner {
        switch self {
        case .topLeft: return .topRight
        case .topRight: return .topLeft
        case .bottomLeft: return .bottomRight
        case .bottomRight: return .bottomLeft
        }
    }
}

enum BurnInCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

/// Burn-in options, persisted in UserDefaults. Folder and name prefix are shared with `RecordingPrefs`.
enum BurnInPrefs {
    static let logoFileKey = "burnInLogoFile"
    static let cornerKey = "burnInCorner"
    static let scaleKey = "burnInScalePercent"
    static let opacityKey = "burnInOpacityPercent"
    static let showTimeKey = "burnInShowTime"
    static let showStatsKey = "burnInShowStats"
    static let codecKey = "burnInCodec"
    static let bitrateKey = "burnInBitrateMbps"
    static let containerKey = "burnInContainer"

    static let scaleRange = 5...100
    static let opacityRange = 0...100
    static let bitrateRange = 2...100
    static let defaultScale = 15
    static let defaultOpacity = 80
    static let defaultBitrate = 12

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// UserDefaults returns 0 for a missing integer key; treat that as "use the default".
    static func int(_ key: String, default def: Int, range: ClosedRange<Int>,
                    defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return def }
        return clamp(defaults.integer(forKey: key), to: range)
    }

    static var corner: BurnInCorner {
        BurnInCorner(rawValue: UserDefaults.standard.string(forKey: cornerKey) ?? "") ?? .topRight
    }
    static var scalePercent: Int { int(scaleKey, default: defaultScale, range: scaleRange) }
    static var opacityPercent: Int { int(opacityKey, default: defaultOpacity, range: opacityRange) }
    static var bitrateMbps: Int { int(bitrateKey, default: defaultBitrate, range: bitrateRange) }
    static var showTime: Bool { UserDefaults.standard.bool(forKey: showTimeKey) }
    static var showStats: Bool { UserDefaults.standard.bool(forKey: showStatsKey) }
    static var codec: BurnInCodec {
        BurnInCodec(rawValue: UserDefaults.standard.string(forKey: codecKey) ?? "") ?? .h264
    }
    static var container: RecordingPrefs.Container {
        RecordingPrefs.Container(rawValue: UserDefaults.standard.string(forKey: containerKey) ?? "") ?? .mov
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GogglesView", isDirectory: true)
    }

    /// The imported logo copy, if one is set and still exists.
    static var logoURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: logoFileKey), !name.isEmpty else { return nil }
        let url = supportDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the chosen image into Application Support so it survives the
    /// original being moved and needs no security-scoped bookmark.
    @discardableResult
    static func importLogo(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased().isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "BurnInLogo.\(ext)"
        let dest = supportDirectory.appendingPathComponent(name)
        if let old = logoURL { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        UserDefaults.standard.set(name, forKey: logoFileKey)
        return dest
    }

    static func clearLogo() {
        if let old = logoURL { try? FileManager.default.removeItem(at: old) }
        UserDefaults.standard.removeObject(forKey: logoFileKey)
    }
}

/// Pure layout/formatting helpers (unit-tested).
enum BurnInLayout {
    /// Edge margin for a frame, ~3% of its height (32 px at 1080p).
    static func margin(for frame: CGSize) -> CGFloat {
        (frame.height * 0.03).rounded()
    }

    /// Logo rect in Core Image coordinates (origin bottom-left). Width is
    /// `scalePercent` of the frame width, aspect preserved, shrunk if needed
    /// so it fits inside the margins.
    static func logoRect(frame: CGSize, logo: CGSize, corner: BurnInCorner,
                         scalePercent: Int, margin: CGFloat) -> CGRect {
        guard logo.width > 0, logo.height > 0, frame.width > 0, frame.height > 0 else { return .zero }
        let scale = CGFloat(BurnInPrefs.clamp(scalePercent, to: BurnInPrefs.scaleRange)) / 100
        let maxW = max(1, frame.width - 2 * margin), maxH = max(1, frame.height - 2 * margin)
        var w = min(frame.width * scale, maxW)
        var h = w * logo.height / logo.width
        if h > maxH { h = maxH; w = h * logo.width / logo.height }
        w = w.rounded(); h = h.rounded()
        return cornerRect(size: CGSize(width: w, height: h), in: frame, corner: corner, margin: margin)
    }

    /// Places a box of `size` in a corner of `frame` (Core Image coordinates).
    static func cornerRect(size: CGSize, in frame: CGSize, corner: BurnInCorner, margin: CGFloat) -> CGRect {
        let x = corner.isLeft ? margin : frame.width - margin - size.width
        let y = corner.isTop ? frame.height - margin - size.height : margin
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func textLines(info: BurnInInfo, date: Date, showTime: Bool, showStats: Bool,
                          timeZone: TimeZone = .current) -> [String] {
        var out: [String] = []
        if showTime {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            out.append(f.string(from: date))
        }
        if showStats {
            var parts: [String] = []
            if let r = info.resolution { parts.append(r) }
            if let fps = info.fps { parts.append("\(fps) fps") }
            if let kbps = info.bitrateKbps { parts.append(String(format: "%.1f Mbps", kbps / 1000)) }
            if !parts.isEmpty { out.append(parts.joined(separator: " · ")) }
        }
        return out
    }

    static func fileName(for date: Date, prefix: String, ext: String, timeZone: TimeZone = .current) -> String {
        Recorder.fileName(for: date, timeZone: timeZone, prefix: "\(prefix)-burned", ext: ext)
    }

    static func defaultURL(date: Date = Date()) -> URL {
        RecordingPrefs.directory.appendingPathComponent(
            fileName(for: date, prefix: RecordingPrefs.prefix, ext: BurnInPrefs.container.ext))
    }
}

/// Everything a burn-in session needs, captured at start.
struct BurnInSettings {
    var logo: CIImage?
    var corner: BurnInCorner = .topRight
    var scalePercent = BurnInPrefs.defaultScale
    var opacityPercent = BurnInPrefs.defaultOpacity
    var showTime = false
    var showStats = false
    var codec: BurnInCodec = .h264
    var bitrateMbps = BurnInPrefs.defaultBitrate

    static func current() -> BurnInSettings {
        BurnInSettings(
            logo: BurnInPrefs.logoURL.flatMap { CIImage(contentsOf: $0) },
            corner: BurnInPrefs.corner, scalePercent: BurnInPrefs.scalePercent,
            opacityPercent: BurnInPrefs.opacityPercent, showTime: BurnInPrefs.showTime,
            showStats: BurnInPrefs.showStats, codec: BurnInPrefs.codec, bitrateMbps: BurnInPrefs.bitrateMbps)
    }
}

/// Re-encoding recorder that burns a logo/text overlay into the video.
/// `enqueue` is called on the decode path (main queue) and only hops the
/// sample onto a private decode queue; compositing + encoding run on a
/// second queue. Frames are dropped rather than ever blocking the caller.
final class BurnInRecorder: ObservableObject, SampleBufferRendering {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published private(set) var droppedFrames = 0

    /// Compressed samples waiting to decode before we give up and resync at a keyframe.
    static let maxPendingDecode = 20
    /// Decoded frames waiting to composite/encode before new ones are dropped.
    static let maxPendingEncode = 3

    private let lock = NSLock()
    private var job: BurnInJob?
    private var infoTimer: Timer?

    init() {}

    var outputURL: URL? { lock.lock(); defer { lock.unlock() }; return job?.url }

    /// Arms the recorder; the file is created at the next keyframe.
    /// `info` is polled on the main queue (2 Hz) while recording.
    func start(to url: URL = BurnInLayout.defaultURL(),
               settings: BurnInSettings = .current(),
               info: @escaping () -> BurnInInfo = { BurnInInfo() }) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.lock()
        guard job == nil else { lock.unlock(); return }
        let j = BurnInJob(url: url, settings: settings, owner: self)
        j.info = info()
        job = j
        lock.unlock()
        DispatchQueue.main.async {
            self.lastError = nil; self.elapsed = 0; self.droppedFrames = 0; self.isRecording = true
            self.infoTimer?.invalidate()
            self.infoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak j] _ in
                j?.setInfo(info())
            }
        }
    }

    /// Drains queued frames and finalizes the file; `completion` gets the URL,
    /// or nil if nothing was written. Called on an arbitrary queue.
    func stop(completion: ((URL?) -> Void)? = nil) {
        lock.lock()
        let j = job
        job = nil
        lock.unlock()
        DispatchQueue.main.async {
            self.infoTimer?.invalidate(); self.infoTimer = nil
            self.isRecording = false
        }
        guard let j else { completion?(nil); return }
        j.finish(completion: completion)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let j = job
        lock.unlock()
        j?.submit(sampleBuffer)
    }

    func flush() {}

    /// Live samples carry no NotSync attachment, so also look for an IDR
    /// (type 5) NAL in the 4-byte-length-prefixed AVCC payload.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return false }
        let total = CMBlockBufferGetDataLength(block)
        var offset = 0
        var head = [UInt8](repeating: 0, count: 5)
        while offset + 5 <= total {
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: 5, destination: &head) == noErr
            else { return false }
            let len = Int(head[0]) << 24 | Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            switch head[4] & 0x1F {
            case 5: return true
            case 1: return false
            default: break
            }
            guard len > 0 else { return false }
            offset += 4 + len
        }
        return false
    }

    // Called by the job from its queues.
    fileprivate func publish(elapsed: TimeInterval?, dropped: Int?) {
        DispatchQueue.main.async {
            if let elapsed { self.elapsed = elapsed }
            if let dropped { self.droppedFrames = dropped }
        }
    }

    fileprivate func fail(_ message: String) {
        Logging.decode.error("burn-in: \(message, privacy: .public)")
        DispatchQueue.main.async { self.lastError = message }
    }
}

/// One recording session's decode/composite/encode state.
private final class BurnInJob {
    let url: URL
    let settings: BurnInSettings
    weak var owner: BurnInRecorder?

    private let decodeQueue = DispatchQueue(label: "GogglesView.burnin.decode", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "GogglesView.burnin.encode", qos: .userInitiated)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var accepting = true
    private var needKeyframe = true
    private var pendingDecode = 0
    private var pendingEncode = 0
    private var dropped = 0
    private var started = false  // drops only count once the first keyframe arrived
    var info = BurnInInfo()

    // decodeQueue only.
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMFormatDescription?

    // encodeQueue only.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var ownPool: CVPixelBufferPool?
    private var outputSize = CGSize.zero
    private var startPTS: CMTime?
    private var lastPTS: CMTime?
    private var lastInterval = CMTime(value: 1, timescale: 60)
    private var failed = false
    private var lastPublish: CFAbsoluteTime = 0
    private var logoLayer: CIImage?
    private var textKey: [String] = []
    private var textLayer: CIImage?
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                .cacheIntermediates: false])

    init(url: URL, settings: BurnInSettings, owner: BurnInRecorder) {
        self.url = url
        self.settings = settings
        self.owner = owner
    }

    func setInfo(_ i: BurnInInfo) { lock.lock(); info = i; lock.unlock() }

    // MARK: Decode side

    func submit(_ sample: CMSampleBuffer) {
        let key = BurnInRecorder.isKeyframe(sample)
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pendingDecode >= BurnInRecorder.maxPendingDecode {
            // Decoder can't keep up; skipping a compressed frame breaks the
            // reference chain, so resync at the next keyframe.
            needKeyframe = true
        }
        if needKeyframe {
            guard key, pendingDecode < BurnInRecorder.maxPendingDecode else {
                if started { dropped += 1 }
                let d = dropped
                lock.unlock()
                owner?.publish(elapsed: nil, dropped: d)
                return
            }
            needKeyframe = false
            if !started, let fmt = CMSampleBufferGetFormatDescription(sample) {
                // Open the writer while the first frame decodes; it takes long
                // enough that the first few frames would otherwise be dropped.
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                encodeQueue.async { [self] in prepareWriter(width: Int(dims.width), height: Int(dims.height)) }
            }
            started = true
        }
        pendingDecode += 1
        lock.unlock()
        decodeQueue.async { [self] in
            decode(sample)
            lock.lock(); pendingDecode -= 1; lock.unlock()
        }
    }

    private func decode(_ sample: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        if decoder == nil || decoderFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fmt) }) ?? true {
            if let d = decoder { VTDecompressionSessionWaitForAsynchronousFrames(d); VTDecompressionSessionInvalidate(d) }
            decoder = nil
            guard BurnInRecorder.isKeyframe(sample) else {
                lock.lock(); needKeyframe = true; lock.unlock()
                return
            }
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
            var s: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
            guard st == noErr, let s else { owner?.fail("decoder create failed (\(st))"); return }
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            decoder = s
            decoderFormat = fmt
        }
        guard let decoder else { return }
        let st = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [],
                                                   infoFlagsOut: nil) { [self] status, _, image, pts, _ in
            guard status == noErr, let image else { return }
            frameDecoded(image, pts: pts)
        }
        if st != noErr {
            // Corrupt sample: wait for a keyframe rather than emitting smeared frames.
            lock.lock(); needKeyframe = true; lock.unlock()
        }
    }

    private func frameDecoded(_ image: CVImageBuffer, pts: CMTime) {
        lock.lock()
        guard pendingEncode < BurnInRecorder.maxPendingEncode else {
            dropped += 1
            let d = dropped
            lock.unlock()
            owner?.publish(elapsed: nil, dropped: d)
            return
        }
        pendingEncode += 1
        lock.unlock()
        encodeQueue.async { [self] in
            encode(image, pts: pts)
            lock.lock(); pendingEncode -= 1; lock.unlock()
        }
    }

    // MARK: Encode side

    private func prepareWriter(width: Int, height: Int) {
        guard writer == nil, !failed, width > 0, height > 0 else { return }
        if !setUpWriter(width: width, height: height) { failed = true }
    }

    private func encode(_ image: CVPixelBuffer, pts: CMTime) {
        prepareWriter(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        guard !failed else { return }
        if startPTS == nil { startPTS = pts }
        guard let writer, let input, let adaptor, let start = startPTS else { return }
        if writer.status == .failed {
            failed = true
            owner?.fail(writer.error?.localizedDescription ?? "writer failed")
            return
        }
        guard input.isReadyForMoreMediaData else { return countDrop() }

        var out: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool ?? ownPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        }
        guard let out else { return countDrop() }
        CVBufferPropagateAttachments(image, out)

        ciContext.render(composite(image), to: out, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: nil)

        var t = Recorder.normalized(pts, relativeTo: start)
        if let last = lastPTS, t <= last + Recorder.minFrameSpacing { t = last + Recorder.minFrameSpacing }
        if let last = lastPTS { lastInterval = t - last }
        lastPTS = t
        if adaptor.append(out, withPresentationTime: t) {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPublish > 0.1 {
                lastPublish = now
                owner?.publish(elapsed: max(0, CMTimeGetSeconds(t)), dropped: nil)
            }
        } else {
            failed = true
            owner?.fail(writer.error?.localizedDescription ?? "append failed")
        }
    }

    /// First CIContext render compiles kernels (tens of ms); do it before frames arrive.
    private func warmUpRenderer() {
        var pb: CVPixelBuffer?
        guard let pool = adaptor?.pixelBufferPool ?? ownPool else { return }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        let base = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
        ciContext.render(logoLayer.map { $0.composited(over: base) } ?? base, to: pb,
                         bounds: CGRect(origin: .zero, size: outputSize), colorSpace: nil)
    }

    private func countDrop() {
        lock.lock(); dropped += 1; let d = dropped; lock.unlock()
        owner?.publish(elapsed: nil, dropped: d)
    }

    private func setUpWriter(width: Int, height: Int) -> Bool {
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
            w.movieFragmentInterval = Recorder.fragmentInterval
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.bitrateMbps * 1_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ]
            if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let output: [String: Any] = [
                AVVideoCodecKey: settings.codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: output)
            inp.expectsMediaDataInRealTime = true
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: poolAttrs)
            guard w.canAdd(inp) else { owner?.fail("cannot add video input"); return false }
            w.add(inp)
            guard w.startWriting() else { owner?.fail(w.error?.localizedDescription ?? "startWriting failed"); return false }
            w.startSession(atSourceTime: .zero)
            if ad.pixelBufferPool == nil {
                CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &ownPool)
            }
            writer = w; input = inp; adaptor = ad
            outputSize = CGSize(width: width, height: height)
            logoLayer = makeLogoLayer()
            warmUpRenderer()
            return true
        } catch {
            owner?.fail(error.localizedDescription)
            return false
        }
    }

    private func composite(_ image: CVPixelBuffer) -> CIImage {
        var base = CIImage(cvPixelBuffer: image)
        if base.extent.size != outputSize, base.extent.width > 0, base.extent.height > 0 {
            // Mid-recording resolution change: stretch to the file's size.
            base = base.transformed(by: CGAffineTransform(scaleX: outputSize.width / base.extent.width,
                                                          y: outputSize.height / base.extent.height))
        }
        if let logoLayer { base = logoLayer.composited(over: base) }
        if let text = currentTextLayer() { base = text.composited(over: base) }
        return base
    }

    private func makeLogoLayer() -> CIImage? {
        guard let logo = settings.logo, settings.opacityPercent > 0 else { return nil }
        let ext = logo.extent
        let rect = BurnInLayout.logoRect(frame: outputSize, logo: ext.size, corner: settings.corner,
                                         scalePercent: settings.scalePercent,
                                         margin: BurnInLayout.margin(for: outputSize))
        guard rect.width > 0 else { return nil }
        let s = rect.width / ext.width
        var img = logo
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let alpha = CGFloat(BurnInPrefs.clamp(settings.opacityPercent, to: BurnInPrefs.opacityRange)) / 100
        if alpha < 1 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
        }
        return img.cropped(to: rect)
    }

    private func currentTextLayer() -> CIImage? {
        guard settings.showTime || settings.showStats else { return nil }
        lock.lock(); let i = info; lock.unlock()
        let lines = BurnInLayout.textLines(info: i, date: Date(), showTime: settings.showTime, showStats: settings.showStats)
        if lines != textKey {
            textKey = lines
            textLayer = Self.renderText(lines, frame: outputSize, corner: settings.corner.mirroredHorizontally)
        }
        return textLayer
    }

    /// Draws white monospaced text on a translucent black box, positioned in `corner`.
    static func renderText(_ lines: [String], frame: CGSize, corner: BurnInCorner) -> CIImage? {
        guard !lines.isEmpty, frame.height > 0 else { return nil }
        let fontSize = max(10, (frame.height * 0.026).rounded())
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let lineH = (font.ascender - font.descender + font.leading).rounded(.up)
        let pad = (fontSize * 0.5).rounded()
        let textW = ctLines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0
        let size = CGSize(width: (textW + 2 * pad).rounded(.up), height: lineH * CGFloat(lines.count) + 2 * pad)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: pad, cornerHeight: pad, transform: nil))
        ctx.fillPath()
        for (k, line) in ctLines.enumerated() {
            ctx.textPosition = CGPoint(x: pad, y: size.height - pad - lineH * CGFloat(k + 1) - font.descender)
            CTLineDraw(line, ctx)
        }
        guard let cg = ctx.makeImage() else { return nil }
        let rect = BurnInLayout.cornerRect(size: size, in: frame, corner: corner, margin: BurnInLayout.margin(for: frame))
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    // MARK: Finish

    func finish(completion: ((URL?) -> Void)?) {
        lock.lock(); accepting = false; lock.unlock()
        decodeQueue.async { [self] in
            if let d = decoder { VTDecompressionSessionWaitForAsynchronousFrames(d); VTDecompressionSessionInvalidate(d) }
            decoder = nil
            encodeQueue.async { [self] in
                guard let writer, writer.status == .writing else {
                    if let writer, writer.status == .failed { owner?.fail(writer.error?.localizedDescription ?? "writer failed") }
                    completion?(nil)
                    return
                }
                input?.markAsFinished()
                if let last = lastPTS { writer.endSession(atSourceTime: last + lastInterval) }
                writer.finishWriting { [self] in
                    if writer.status != .completed { owner?.fail(writer.error?.localizedDescription ?? "finish failed") }
                    completion?(writer.status == .completed ? url : nil)
                }
            }
        }
    }
}
