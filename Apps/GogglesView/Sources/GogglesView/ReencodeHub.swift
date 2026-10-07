import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import VideoToolbox
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The goggles send one IDR when Share Liveview starts and none after, so anything that needs to
/// start cleanly later (replay clips, network streams, players that join late) cannot use the raw
/// stream. This hub re-encodes the picture the display decoder already produces with a real IDR
/// every second and fans the result out to subscribers. It only runs while someone subscribes.
enum ReencodePrefs {
    static let enabledKey = "reencodeEnabled"
    static let bitrateKey = "reencodeBitrateMbps"
    static let bitrateRange = 4...60
    static let defaultBitrate = 20

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var bitrateMbps: Int {
        let v = UserDefaults.standard.object(forKey: bitrateKey) as? Int ?? defaultBitrate
        return min(max(v, bitrateRange.lowerBound), bitrateRange.upperBound)
    }
}

final class ReencodeHub {
    /// Picture currently on screen. Called on the main queue by the timer, or by `pollOnce()` in tests.
    private let source: () -> CVPixelBuffer?
    private let bitrateMbps: () -> Int
    private let onIdle: () -> Void
    private let lock = NSLock()
    private var subscribers: [WeakSub] = []
    private var timer: DispatchSourceTimer?

    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var encoderSize: (w: Int, h: Int)?
    private var lastSurface: (id: UInt32, seed: UInt32)?
    /// Counts decoded pictures. When present it decides "new picture or not": the IOSurface change counter is
    /// not reliable for this, because handing the buffer to the encoder bumps it and the hub then re-encodes
    /// the same picture on every poll (a 35 fps source came out as about 60 fps with duplicate frames).
    private let sequence: (() -> UInt64)?
    private var lastSequence: UInt64?

    private(set) var framesEncoded = 0
    private(set) var lastError: String?

    private struct WeakSub { weak var value: SampleBufferRendering? }

    init(source: @escaping () -> CVPixelBuffer?, sequence: (() -> UInt64)? = nil,
         bitrateMbps: @escaping () -> Int = { ReencodePrefs.bitrateMbps },
         onIdle: @escaping () -> Void = {}) {
        self.source = source
        self.sequence = sequence
        self.onIdle = onIdle
        self.bitrateMbps = bitrateMbps
    }

    deinit { teardownEncoder() }

    // MARK: Subscription

    func subscribe(_ c: SampleBufferRendering) {
        lock.lock()
        subscribers.removeAll { $0.value == nil || $0.value === c }
        subscribers.append(WeakSub(value: c))
        let first = subscribers.count == 1
        lock.unlock()
        if first { DispatchQueue.main.async { self.startTimer() } }
    }

    func unsubscribe(_ c: SampleBufferRendering) {
        lock.lock()
        subscribers.removeAll { $0.value == nil || $0.value === c }
        let empty = subscribers.isEmpty
        lock.unlock()
        if empty { DispatchQueue.main.async { self.stopTimer() } }
    }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscribers.filter { $0.value != nil }.count }

    // MARK: Timer (main queue)

    private func startTimer() {
        guard timer == nil, subscriberCount > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in self?.pollOnce() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        guard subscriberCount == 0 else { return }
        timer?.cancel(); timer = nil
        teardownEncoder()
        lastSurface = nil
        lastSequence = nil
        onIdle()
    }

    // MARK: Encoding

    /// Grabs the displayed picture and encodes it if it changed since the last call.
    func pollOnce() {
        guard let buf = source() else { return }
        if let sequence {
            let n = sequence()
            if lastSequence == n { return }
            lastSequence = n
        } else if let surface = CVPixelBufferGetIOSurface(buf)?.takeUnretainedValue() {
            let key = (id: IOSurfaceGetID(surface), seed: IOSurfaceGetSeed(surface))
            if let last = lastSurface, last == key { return }
            lastSurface = key
        }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        if encoderSize?.w != w || encoderSize?.h != h { setUpEncoder(width: w, height: h) }
        guard let session, let input = convertedInput(buf) else { return }
        let pts = CMTime(value: Int64(clamping: DispatchTime.now().uptimeNanoseconds), timescale: 1_000_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: input, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.fanOut(sample)
        }
        if status != noErr { lastError = "encode failed (\(status))" }
    }

    private func fanOut(_ sample: CMSampleBuffer) {
        lock.lock()
        let subs = subscribers.compactMap(\.value)
        framesEncoded += 1
        lock.unlock()
        for s in subs { s.enqueue(sample) }
    }

    /// Hardware H.264 takes 8-bit 4:2:0; the display layer hands us 10-bit, so convert when needed.
    private func convertedInput(_ buf: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return buf }
        guard let transfer, let pool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: buf, to: dst) == noErr else { return nil }
        return dst
    }

    private func setUpEncoder(width: Int, height: Int) {
        teardownEncoder()
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { lastError = "encoder create failed (\(st))"; return }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrateMbps() * 1_000_000))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 120))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        encoderSize = (width, height)

        var t: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t) == noErr { transfer = t }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
        lastError = nil
        Logging.recorder.info("keyframe encoder started: \(width)x\(height), \(self.bitrateMbps()) Mbps")
    }

    private func teardownEncoder() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
        session = nil; transfer = nil; pool = nil; encoderSize = nil
    }
}

#if canImport(SwiftUI)
struct ReencodeSettingsSection: View {
    @AppStorage(ReencodePrefs.enabledKey) private var enabled = true
    @AppStorage(ReencodePrefs.bitrateKey) private var bitrate = ReencodePrefs.defaultBitrate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyframes for replay and streams").font(.headline)
            Toggle("Re-encode with regular keyframes", isOn: $enabled)
            Stepper("Bitrate: \(bitrate) Mbps", value: $bitrate, in: ReencodePrefs.bitrateRange)
                .disabled(!enabled)
            Text("The goggles send one keyframe when Share Liveview starts and none after, so instant replay, UDP, RTMP, SRT and the web viewer can't start cleanly later. This re-encodes the picture with a keyframe every second (hardware encoder, runs only while one of those is active). Turn it off to pass the goggles' stream through untouched; clips and late-joining viewers may then show grey until the next keyframe.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
