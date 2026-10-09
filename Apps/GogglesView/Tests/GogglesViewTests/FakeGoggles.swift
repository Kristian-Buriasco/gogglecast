import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import GogglesView

/// A software stand-in for the goggles: renders an animated 1920x1080 test picture, encodes it with
/// VideoToolbox like the goggles do (High profile, no B-frames, ONE IDR at the start and only P frames
/// after), cuts it into Annex-B NAL units with 4-byte start codes, repeats SPS+PPS about five times a
/// second and feeds everything into `DecodeSession.handle(...)` exactly like `HelperClient.onNALUnit`.
///
/// Everything that reaches a session is delivered from one serial queue, so the session sees the same
/// single-threaded call pattern as in the app.
final class FakeGoggles {
    struct Options {
        var width = 1920
        var height = 1080
        var fps = 60.0
        /// Pace frames at `fps` wall-clock; false renders as fast as the encoder allows.
        var realTime = true
        /// Synthetic hand-held camera shake: the whole picture jitters.
        var shake = false
        /// Moving shapes over the texture; off leaves only the textured background (and the shake).
        var shapes = true
        /// Peak shake displacement in pixels.
        var shakeAmplitude = 22.0
        var parameterSetHz = 5.0
        var bitrateMbps = 14
    }

    let options: Options
    private let sinkLock = NSLock()
    private var sinks: [DecodeSession]
    private let deliverQueue = DispatchQueue(label: "fakegoggles.deliver")

    // Control state, guarded by `lock`.
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var silent = false
    private var dropRemaining = 0
    private var notifyDrop = false
    private var forceKey = false
    private var shaking: Bool
    private var _framesRendered = 0
    private var _framesDelivered = 0
    private var _idrDelivered = 0
    private var _parameterSetsDelivered = 0
    private var _lastDeliveredAt: Date?
    private var bundledParameterSets: Data?
    private var lastParameterSetAt = Date.distantPast

    var framesRendered: Int { locked { _framesRendered } }
    var framesDelivered: Int { locked { _framesDelivered } }
    var idrDelivered: Int { locked { _idrDelivered } }
    var parameterSetsDelivered: Int { locked { _parameterSetsDelivered } }
    var lastDeliveredAt: Date? { locked { _lastDeliveredAt } }

    private var encoder: VTCompressionSession?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var background: CIImage?
    private static let pad = 80
    private let inFlight: DispatchSemaphore

    init(session: DecodeSession, options: Options = Options()) {
        self.options = options
        self.sinks = [session]
        self.shaking = options.shake
        self.inFlight = DispatchSemaphore(value: 6)
    }

    deinit { stop() }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: Control

    /// Starts rendering and delivering. The first delivered frame is the stream's only IDR, preceded by SPS+PPS.
    func start() throws {
        try locked {
            guard !running else { return }
            try makeEncoder()
            makeBackground()
            running = true
        }
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "fakegoggles.render"
        t.qualityOfService = .userInitiated
        locked { thread = t }
        t.start()
    }

    func stop() {
        let enc: VTCompressionSession? = locked {
            running = false
            let e = encoder; encoder = nil
            return e
        }
        guard let enc else { return }
        // Let the render thread leave its loop before the encoder goes away.
        Thread.sleep(forTimeInterval: 0.05)
        VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(enc)
        deliverQueue.sync {}
    }

    /// Nothing reaches any session while silent (the helper reports no NALs), but the encoder keeps going,
    /// so on resume the stream continues with P frames and no new IDR unless `requestKeyframe()` is called.
    func setSilent(_ on: Bool) { locked { silent = on } }

    /// Loses the next `frames` frames. With `notifyingSessions`, also tells each session its input was
    /// dropped, which is what the connection coordinator does when NAL backpressure drops data.
    func dropFrames(_ frames: Int, notifyingSessions: Bool = true) {
        locked { dropRemaining = frames; notifyDrop = notifyingSessions }
    }

    /// The next frame becomes an IDR, preceded by SPS+PPS (what a "request keyframe" would trigger).
    func requestKeyframe() { locked { forceKey = true } }

    func setShake(_ on: Bool) { locked { shaking = on } }

    /// A viewer that connects mid-stream: `session` receives everything from now on, so it sees
    /// parameter sets but never the IDR.
    func joinLate(_ session: DecodeSession) {
        sinkLock.lock(); sinks.append(session); sinkLock.unlock()
        if let ps = locked({ bundledParameterSets }) {
            deliverQueue.async { session.handle(nalData: ps, nalType: 7, isParameterSet: true, hostTime: Self.now()) }
        }
    }

    /// A late-joining keyframe-safe consumer on `session` (replay, network outputs, web viewer).
    func joinLate(consumer: SampleBufferRendering, on session: DecodeSession) {
        session.addKeyframeSafeConsumer(consumer)
    }

    // MARK: Encoder

    func makeEncoder() throws {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(options.width), height: Int32(options.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw FakeGogglesError.encoder(st) }
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: options.bitrateMbps * 1_000_000))
        // One IDR only: no periodic keyframes.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int32.max))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1_000_000))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: options.fps))
        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: options.width, kCVPixelBufferHeightKey: options.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
    }

    // MARK: Picture

    /// Static texture, larger than the frame so shake never reveals an edge: coarse colour noise blocks (12 px, they survive compression, so a motion estimator can lock on)
    /// plus a gradient, so the encoder has real detail to chew on and the stabilizer has something to track.
    func makeBackground() {
        let w = options.width + 2 * Self.pad, h = options.height + 2 * Self.pad
        let small = CGRect(x: 0, y: 0, width: w / 12 + 2, height: h / 12 + 2)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: small)
        let toned = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.30, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.30, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.30, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.25, y: 0.25, z: 0.25, w: 1),
        ])
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(w), y: CGFloat(h)),
            "inputColor0": CIColor(red: 0.10, green: 0.25, blue: 0.55),
            "inputColor1": CIColor(red: 0.75, green: 0.55, blue: 0.20),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let scaled = toned.samplingNearest().transformed(by: CGAffineTransform(scaleX: 12, y: 12))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // Static high-contrast landmarks (fixed in the world, so they move only with the camera).
        var world = scaled.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gradient])
        for i in 0..<28 {
            let x = Double((i * 397) % (w - 220)) + 20, y = Double((i * 211) % (h - 160)) + 20
            let c = i % 2 == 0 ? CIColor(red: 0.97, green: 0.97, blue: 0.97) : CIColor(red: 0.03, green: 0.03, blue: 0.06)
            world = CIImage(color: c).cropped(to: CGRect(x: x, y: y, width: 40 + Double(i % 5) * 28, height: 30 + Double(i % 4) * 30)).composited(over: world)
        }
        let mixed = world
        // Bake once so every frame only translates a bitmap.
        if let cg = ci.createCGImage(mixed, from: CGRect(x: 0, y: 0, width: w, height: h)) {
            background = CIImage(cgImage: cg)
        } else {
            background = mixed
        }
    }

    /// Camera offset in pixels for frame `n`: a few incommensurate sines plus a pseudo-random wobble.
    static func shakeOffset(frame n: Int, amplitude a: Double) -> CGPoint {
        let t = Double(n)
        let x = a * (0.55 * sin(t * 0.37) + 0.30 * sin(t * 1.13 + 1.0) + 0.15 * sin(t * 2.9 + 2.0))
        let y = a * (0.55 * sin(t * 0.29 + 0.5) + 0.30 * sin(t * 0.97 + 2.5) + 0.15 * sin(t * 3.3))
        return CGPoint(x: x, y: y)
    }

    func renderFrame(_ n: Int, shake: Bool) -> CVPixelBuffer? {
        guard let pool, let background else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        let t = Double(n) / options.fps
        let w = Double(options.width), h = Double(options.height)
        let off = shake ? Self.shakeOffset(frame: n, amplitude: options.shakeAmplitude) : .zero
        let pad = Double(Self.pad)

        var image = background

        func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double, _ c: CIColor) -> CIImage {
            CIImage(color: c).cropped(to: CGRect(x: x + pad, y: y + pad, width: rw, height: rh))
        }
        func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx + pad, y: cy + pad), "inputRadius0": r, "inputRadius1": r + 1,
                "inputColor0": c, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])!.outputImage!.cropped(to: CGRect(x: cx + pad - r - 2, y: cy + pad - r - 2, width: 2 * r + 4, height: 2 * r + 4))
        }
        let shapes: [CIImage] = [
            rect(w * (0.15 + 0.55 * (0.5 + 0.5 * sin(t * 0.9))), h * 0.18, 260, 160, CIColor(red: 0.9, green: 0.15, blue: 0.1)),
            rect(w * 0.7, h * (0.2 + 0.5 * (0.5 + 0.5 * sin(t * 1.3 + 1))), 180, 280, CIColor(red: 0.1, green: 0.85, blue: 0.3)),
            disc(w * (0.5 + 0.3 * cos(t * 1.1)), h * (0.5 + 0.3 * sin(t * 1.7)), 120, CIColor(red: 1, green: 1, blue: 0.1)),
            disc(w * (0.3 + 0.25 * sin(t * 0.6 + 2)), h * (0.7 + 0.2 * cos(t * 2.1)), 70, CIColor(red: 0.95, green: 0.95, blue: 0.95)),
        ]
        if options.shapes { for s in shapes { image = s.composited(over: image) } }

        // The visible window slides over the padded scene by the camera offset.
        let window = CGRect(x: pad + off.x, y: pad + off.y, width: w, height: h)
        image = image.cropped(to: window).transformed(by: CGAffineTransform(translationX: -window.minX, y: -window.minY))
        ci.render(image, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return pb
    }

    // MARK: Loop

    private func runLoop() {
        let interval = 1.0 / options.fps
        var next = DispatchTime.now().uptimeNanoseconds
        var n = 0
        while true {
            let (alive, enc, force, shake) = locked { () -> (Bool, VTCompressionSession?, Bool, Bool) in
                let f = forceKey && n > 0; if f { forceKey = false }
                return (running, encoder, f, shaking)
            }
            guard alive, let enc else { return }
            if options.realTime {
                let now = DispatchTime.now().uptimeNanoseconds
                if now < next { Thread.sleep(forTimeInterval: Double(next - now) / 1e9) }
                else if now - next > 250_000_000 { next = now }   // fell behind: resync instead of bursting
                next += UInt64(interval * 1e9)
            }
            guard inFlight.wait(timeout: .now() + 2) == .success else { continue }
            // Without a pool per iteration, Core Image's autoreleased objects pile up on this thread.
            let pbOrNil = autoreleasepool { renderFrame(n, shake: shake) }
            guard let pb = pbOrNil else { inFlight.signal(); n += 1; continue }
            let hostNs = DispatchTime.now().uptimeNanoseconds
            let pts = CMTime(value: Int64(hostNs), timescale: 1_000_000_000)
            let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            locked { _framesRendered += 1 }
            let st = VTCompressionSessionEncodeFrame(enc, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
                defer { self?.inFlight.signal() }
                guard status == noErr, let sample, let self else { return }
                self.emit(sample, forcedKey: force)
            }
            if st != noErr { inFlight.signal() }
            n += 1
        }
    }

    // MARK: Annex-B delivery

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static let startCode = Data([0, 0, 0, 1])

    private func emit(_ sample: CMSampleBuffer, forcedKey: Bool) {
        let isKey: Bool = {
            if let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
               let first = a.first, (first[kCMSampleAttachmentKey_NotSync] as? Bool) == true { return false }
            return true
        }()
        var ps: Data?
        if let fd = CMSampleBufferGetFormatDescription(sample) { ps = Self.annexBParameterSets(fd) }
        if let ps { locked { bundledParameterSets = ps } }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var base: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base) == kCMBlockBufferNoErr,
              let base else { return }
        let bytes = Data(bytes: base, count: length)
        var nals: [Data] = []
        var i = 0
        while i + 4 <= bytes.count {
            let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let s = i + 4
            guard len > 0, s + len <= bytes.count else { break }
            // The goggles' stream carries only slices (types 1 and 5) and the bundled parameter sets: drop the
            // encoder's SEI / AUD NAL units so the app is fed what the helper really emits.
            let type = bytes[s] & 0x1F
            if type == 1 || type == 5 { nals.append(Self.startCode + bytes[s..<(s + len)]) }
            i = s + len
        }
        let hostTime = Self.now()

        // Decide what this frame does under the control flags.
        let action: (deliver: Bool, notify: Bool) = locked {
            if dropRemaining > 0 { dropRemaining -= 1; let n = notifyDrop; return (false, n) }
            if silent { return (false, false) }
            return (true, false)
        }
        let wantParams = locked { () -> Bool in
            let due = Date().timeIntervalSince(lastParameterSetAt) >= 1.0 / options.parameterSetHz
            if (due || isKey) && action.deliver { lastParameterSetAt = Date(); return true }
            return false
        }
        sinkLock.lock(); let targets = sinks; sinkLock.unlock()
        deliverQueue.async { [self] in
            if action.notify { for t in targets { t.noteInputDropped() } }
            guard action.deliver else { return }
            // Sessions are fed in parallel (each real goggles has its own delivery thread); frames stay in
            // order because this queue is serial and concurrentPerform returns only when all are done.
            if wantParams, let ps = locked({ bundledParameterSets }) {
                DispatchQueue.concurrentPerform(iterations: targets.count) {
                    targets[$0].handle(nalData: ps, nalType: 7, isParameterSet: true, hostTime: hostTime)
                }
                locked { _parameterSetsDelivered += 1 }
            }
            for nal in nals {
                let type = nal[nal.startIndex + 4] & 0x1F
                DispatchQueue.concurrentPerform(iterations: targets.count) {
                    targets[$0].handle(nalData: nal, nalType: type, isParameterSet: false, hostTime: hostTime)
                }
            }
            locked {
                _framesDelivered += 1
                if isKey { _idrDelivered += 1 }
                _lastDeliveredAt = Date()
            }
        }
    }

    /// SPS+PPS from a format description as one Annex-B blob, like the goggles' bundled parameter sets.
    static func annexBParameterSets(_ fd: CMFormatDescription) -> Data? {
        var out = Data()
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                nalUnitHeaderLengthOut: nil) == noErr else { return nil }
        for idx in 0..<count {
            var p: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: idx, parameterSetPointerOut: &p,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil) == noErr, let p else { return nil }
            out.append(startCode)
            out.append(p, count: size)
        }
        return out
    }
}

enum FakeGogglesError: Error { case encoder(OSStatus) }

