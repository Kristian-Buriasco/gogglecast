import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import Metal
import MetalFX
#if canImport(SwiftUI)
import SwiftUI
#endif

// ─────────────────────────────────────────────────────────────────────────
// Picture enhancement: a temporal noise reducer ("ISO reducer") and an upscaler.
//
//   noise reduction: Apple's VideoToolbox temporal noise filter where the Mac supports it (macOS 26, newer chips),
//                    otherwise our own motion-adaptive temporal filter in Core Image (any Mac the app runs on).
//   upscaling:       MetalFX's spatial scaler (macOS 13+, Apple silicon). Apple's VideoToolbox super-resolution
//                    scalers were tried first and do not fit: the low-latency one refuses inputs above 1280 pixels
//                    (so no 1080p), the other only does 4x and needs a model download.
//
// They sit in the decode path next to the stabilizer, so the preview, recordings, streams and the
// capture window all get the enhanced picture:
//
//     decoded picture -> denoise -> stabilize -> upscale
//
// Denoise goes first so the stabilizer measures motion on a cleaner picture; upscaling goes last so it also wins
// back detail the stabilizer's zoom softened. Both are causal (no future frames), so they add no frames of delay,
// only their own processing time, and both bypass themselves when they cost too much of the frame interval, the
// same budget rule as the stabilizer.
// ─────────────────────────────────────────────────────────────────────────

enum EnhancePrefs {
    static let denoiseKey = "denoiseEnabled"
    static let denoiseStrengthKey = "denoiseStrength"
    static let upscaleKey = "upscaleEnabled"
    static let upscaleFactorKey = "upscaleFactor"
    static let defaultStrength = 0.5
    static let defaultUpscaleFactor = 2.0

    static var denoise: Bool { UserDefaults.standard.bool(forKey: denoiseKey) }
    static var upscale: Bool { UserDefaults.standard.bool(forKey: upscaleKey) }
    static var denoiseStrength: Double {
        min(max(UserDefaults.standard.object(forKey: denoiseStrengthKey) as? Double ?? defaultStrength, 0), 1)
    }
    static var upscaleFactor: Double {
        let v = UserDefaults.standard.object(forKey: upscaleFactorKey) as? Double ?? defaultUpscaleFactor
        return v > 0 ? v : defaultUpscaleFactor
    }
    static var anyEnabled: Bool { denoise || upscale }
}

enum EnhanceSupport {
    /// Always available: Apple's filter where supported, our Core Image filter otherwise.
    static var denoise: Bool { true }
    /// Apple's hardware filter in use (macOS 26 and a supporting chip), rather than the Core Image fallback.
    static var denoiseUsesApple: Bool {
        if #available(macOS 26.0, *) { return VTTemporalNoiseFilterConfiguration.isSupported }
        return false
    }
    static var upscale: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }
    static var any: Bool { denoise || upscale }
}

/// What the enhancer did since the last `resetStats()`: for diagnostics and the `--enhance-probe` dev flag.
struct EnhanceStats: Equatable {
    var frames = 0
    var denoised = 0
    var upscaled = 0
    var failures = 0
    var denoiseMs = 0.0   // summed
    var upscaleMs = 0.0   // summed
    var outputWidth = 0
    var outputHeight = 0
    var meanDenoiseMs: Double { denoised > 0 ? denoiseMs / Double(denoised) : 0 }
    var meanUpscaleMs: Double { upscaled > 0 ? upscaleMs / Double(upscaled) : 0 }
}

/// Runs a frame processor's async API to completion, with a timeout so a stuck GPU never stalls the decoder.
/// Returns nil on success, else the reason.
@available(macOS 26.0, *)
private func runSync(_ processor: VTFrameProcessor, _ parameters: VTFrameProcessorParameters, timeout: TimeInterval = 0.25) -> String? {
    final class Box: @unchecked Sendable { var error: String? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    processor.process(parameters: parameters) { _, error in
        if let error { box.error = "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)" }
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) != .success { return "timed out after \(Int(timeout * 1000)) ms" }
    return box.error
}

/// Pixel buffer pool for a processor's destination: the processor's own attributes decide format and backing.
private func makePool(attributes: [String: Any]) -> CVPixelBufferPool? {
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    return pool
}

private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var b: CVPixelBuffer?
    return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) == kCVReturnSuccess ? b : nil
}

/// Converts a picture to another pixel format (hardware transfer), for processors that do not take what the decoder makes.
private final class FormatConverter {
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var key: (w: Int, h: Int, fmt: OSType)?

    func convert(_ input: CVPixelBuffer, to fmt: OSType) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        if key?.w != w || key?.h != h || key?.fmt != fmt {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: fmt, kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = makePool(attributes: attrs)
            key = (w, h, fmt)
        }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let transfer, let pool, let out = makeBuffer(from: pool),
              VTPixelTransferSessionTransferImage(transfer, from: input, to: out) == noErr else { return nil }
        return out
    }

    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
}

@available(macOS 26.0, *)
final class DenoiseStage {
    private let processor = VTFrameProcessor()
    private let converter = FormatConverter()
    private var config: VTTemporalNoiseFilterConfiguration?
    private var pool: CVPixelBufferPool?
    private var active = false
    private var key: (w: Int, h: Int, fmt: OSType)?
    private var previous: [VTFrameProcessorFrame] = []
    private var discontinuity = true
    private(set) var lastError: String?

    func reset() { previous.removeAll(); discontinuity = true }

    deinit { if active { processor.endSession() } }

    private func start(width: Int, height: Int, format: OSType) -> Bool {
        if active { processor.endSession(); active = false }
        previous.removeAll(); discontinuity = true
        guard let cfg = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height, sourcePixelFormat: format) else {
            lastError = "denoise: configuration refused \(width)x\(height) format \(format)"
            return false
        }
        do { try processor.startSession(configuration: cfg) } catch {
            lastError = "denoise: session failed: \(error.localizedDescription)"
            return false
        }
        config = cfg
        pool = makePool(attributes: cfg.destinationPixelBufferAttributes)
        active = true
        key = (width, height, format)
        lastError = nil
        return true
    }

    /// Source formats the filter takes (it refuses others), first choice first.
    private static var sourceFormats: [OSType] {
        VTTemporalNoiseFilterConfiguration.__supportedSourcePixelFormats.map { OSType(truncating: $0) }
    }

    func process(_ input: CVPixelBuffer, pts: CMTime, strength: Float) -> CVPixelBuffer? {
        var src = input
        var fmt = CVPixelBufferGetPixelFormatType(input)
        if !Self.sourceFormats.contains(fmt) {
            guard let target = Self.sourceFormats.first, let converted = converter.convert(input, to: target) else {
                lastError = "denoise: cannot convert format \(fmt)"
                return nil
            }
            src = converted; fmt = target
        }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if !active || key?.w != w || key?.h != h || key?.fmt != fmt {
            guard start(width: w, height: h, format: fmt) else { return nil }
        }
        guard let config, let pool, let dst = makeBuffer(from: pool),
              let srcFrame = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
              let dstFrame = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts),
              let params = VTTemporalNoiseFilterParameters(
                sourceFrame: srcFrame, nextFrames: [], previousFrames: previous, destinationFrame: dstFrame,
                filterStrength: strength, hasDiscontinuity: discontinuity) else {
            lastError = "denoise: could not build parameters"
            return nil
        }
        if let failure = runSync(processor, params) {
            lastError = "denoise: \(failure)"
            reset()
            return nil
        }
        discontinuity = false
        previous.append(srcFrame)
        let keep = max(config.previousFrameCount ?? 0, 0)
        if previous.count > keep { previous.removeFirst(previous.count - keep) }
        return dst
    }
}

/// Motion-adaptive temporal noise reduction in Core Image, for Macs without Apple's hardware filter.
/// Each pixel is blended with the previous OUTPUT picture (a recursive filter, so noise averages out over many
/// frames) unless it differs from it by more than a noise-sized amount, which means real motion: those pixels
/// are taken from the current picture unchanged, so moving subjects do not smear.
final class CITemporalDenoiser {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var previous: CVPixelBuffer?
    private var key: (w: Int, h: Int, fmt: OSType)?
    private(set) var lastError: String?

    func reset() { previous = nil }

    /// `strength` 0...1 sets how long the memory is (more smoothing) and how much difference still counts as noise.
    static func parameters(strength: Double) -> (weight: Double, threshold: Double) {
        let s = min(max(strength, 0), 1)
        return (weight: 0.2 + 0.7 * s, threshold: 0.04 + 0.08 * s)
    }

    /// The Core Image graph of every picture creates autoreleased objects; the decoder's thread does not drain them
    /// often enough, so they piled up at several feeds (22 MB/min in the soak test). Drain after each picture.
    func process(_ input: CVPixelBuffer, strength: Double) -> CVPixelBuffer? {
        autoreleasepool { processUnpooled(input, strength: strength) }
    }

    private func processUnpooled(_ input: CVPixelBuffer, strength: Double) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        let fmt = CVPixelBufferGetPixelFormatType(input)
        if key?.w != w || key?.h != h || key?.fmt != fmt {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: fmt, kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = makePool(attributes: attrs)
            key = (w, h, fmt)
            previous = nil
        }
        guard let pool, let out = makeBuffer(from: pool) else { lastError = "denoise: no output buffer"; return nil }
        let cur = CIImage(cvPixelBuffer: input)
        let space = cur.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)
        var result = cur
        if let prev = previous {
            let (weight, threshold) = Self.parameters(strength: strength)
            let prevImage = CIImage(cvPixelBuffer: prev)
            // soft threshold: no motion up to `threshold` (noise sized), full motion from 3x that
            let gain = CGFloat(1 / (2 * threshold))
            let diff = cur.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: prevImage])
            // one grey value per pixel: how far this pixel moved from the previous output, scaled so "noise sized" is 1
            let g = gain / 3
            let mask = diff
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: g, y: g, z: g, w: 0), "inputGVector": CIVector(x: g, y: g, z: g, w: 0),
                    "inputBVector": CIVector(x: g, y: g, z: g, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 2])
                .cropped(to: cur.extent)
            let blended = cur.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: prevImage, kCIInputTimeKey: weight])
            result = cur.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blended, kCIInputMaskImageKey: mask])
        }
        ci.render(result, to: out, bounds: cur.extent, colorSpace: space)
        if let atts = CVBufferCopyAttachments(input, .shouldPropagate) { CVBufferSetAttachments(out, atts, .shouldPropagate) }
        previous = out
        lastError = nil
        return out
    }
}

/// MetalFX spatial upscaling of one picture stream.
final class MetalFXUpscaler {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let converter = FormatConverter()
    private var scaler: MTLFXSpatialScaler?
    private var pool: CVPixelBufferPool?
    private var key: (w: Int, h: Int, ow: Int, oh: Int)?
    private(set) var lastError: String?

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    private func texture(_ buffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
        guard let device, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
    }

    func process(_ input: CVPixelBuffer, factor: Double) -> CVPixelBuffer? {
        autoreleasepool { processUnpooled(input, factor: factor) }
    }

    private func processUnpooled(_ input: CVPixelBuffer, factor: Double) -> CVPixelBuffer? {
        guard let device, let queue else { lastError = "upscale: no Metal device"; return nil }
        var src = input
        if CVPixelBufferGetPixelFormatType(input) != kCVPixelFormatType_32BGRA {
            guard let converted = converter.convert(input, to: kCVPixelFormatType_32BGRA) else { lastError = "upscale: cannot convert to BGRA"; return nil }
            src = converted
        }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let ow = Int((Double(w) * factor).rounded()) & ~1, oh = Int((Double(h) * factor).rounded()) & ~1
        if key?.w != w || key?.h != h || key?.ow != ow || key?.oh != oh || scaler == nil {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = w; d.inputHeight = h; d.outputWidth = ow; d.outputHeight = oh
            d.colorTextureFormat = .bgra8Unorm; d.outputTextureFormat = .bgra8Unorm
            d.colorProcessingMode = .perceptual
            guard let s = d.makeSpatialScaler(device: device) else { lastError = "upscale: MetalFX refused \(w)x\(h) -> \(ow)x\(oh)"; return nil }
            scaler = s
            pool = makePool(attributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: ow,
                kCVPixelBufferHeightKey as String: oh, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            key = (w, h, ow, oh)
        }
        guard let scaler, let pool, let out = makeBuffer(from: pool),
              let inTex = texture(src, usage: [.shaderRead]),
              let outTex = texture(out, usage: [.renderTarget, .shaderRead, .shaderWrite]),
              let cb = queue.makeCommandBuffer() else { lastError = "upscale: could not set up textures"; return nil }
        scaler.colorTexture = inTex
        scaler.outputTexture = outTex
        scaler.encode(commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status != .completed { lastError = "upscale: GPU error \(cb.error?.localizedDescription ?? "unknown")"; return nil }
        if let atts = CVBufferCopyAttachments(input, .shouldPropagate) { CVBufferSetAttachments(out, atts, .shouldPropagate) }
        lastError = nil
        return out
    }
}

/// Runs the enabled stages for one picture stream. One per decode session.
final class VideoEnhancer {
    private let statLock = NSLock()
    private var appleDenoiser: Any?
    private let softwareDenoiser = CITemporalDenoiser()
    private let upscaler = MetalFXUpscaler()
    private var clockWatch = FrameClockWatch()
    private var denoiseBudget = StabilizerBudget()
    private var upscaleBudget = StabilizerBudget()
    private var _stats = EnhanceStats()
    private var _lastError: String?
    private var resetRequested = false

    var stats: EnhanceStats { statLock.lock(); defer { statLock.unlock() }; return _stats }
    func resetStats() { statLock.lock(); _stats = EnhanceStats(); statLock.unlock() }
    var lastError: String? { statLock.lock(); defer { statLock.unlock() }; return _lastError }

    /// The picture timeline jumped (decoder reset, reconnect): the denoiser must not blend across it.
    func reset() { statLock.lock(); resetRequested = true; statLock.unlock() }

    func noteTimestamp(_ ns: Int64) {
        statLock.lock()
        if clockWatch.note(ns) { resetRequested = true }
        statLock.unlock()
    }

    private static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private func note(error: String?) { statLock.lock(); if let error { _lastError = error; _stats.failures += 1 }; statLock.unlock() }

    func denoise(_ input: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer {
        guard EnhancePrefs.denoise, !RaceModePrefs.enabled else { return input }
        statLock.lock()
        let bypass = denoiseBudget.isBypassed(atMs: Self.nowMs())
        let doReset = resetRequested
        resetRequested = false
        statLock.unlock()
        if bypass { return input }
        let start = DispatchTime.now().uptimeNanoseconds
        let strength = EnhancePrefs.denoiseStrength
        var output: CVPixelBuffer?
        var failure: String?
        if #available(macOS 26.0, *), EnhanceSupport.denoiseUsesApple {
            let stage = (appleDenoiser as? DenoiseStage) ?? DenoiseStage()
            appleDenoiser = stage
            if doReset { stage.reset() }
            output = stage.process(input, pts: pts, strength: Float(strength))
            failure = stage.lastError
        } else {
            if doReset { softwareDenoiser.reset() }
            output = softwareDenoiser.process(input, strength: strength)
            failure = softwareDenoiser.lastError
        }
        guard let out = output else { note(error: failure); return input }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        statLock.lock()
        _stats.denoised += 1; _stats.denoiseMs += ms
        denoiseBudget.record(costMs: ms, intervalMs: clockWatch.intervalMs, atMs: Self.nowMs())
        statLock.unlock()
        return out
    }

    func upscale(_ input: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer {
        statLock.lock(); _stats.frames += 1; statLock.unlock()
        guard EnhancePrefs.upscale, !RaceModePrefs.enabled, EnhanceSupport.upscale else { return input }
        statLock.lock()
        let bypass = upscaleBudget.isBypassed(atMs: Self.nowMs())
        statLock.unlock()
        if bypass { return input }
        let start = DispatchTime.now().uptimeNanoseconds
        guard let out = upscaler.process(input, factor: EnhancePrefs.upscaleFactor) else {
            note(error: upscaler.lastError)
            return input
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        statLock.lock()
        _stats.upscaled += 1; _stats.upscaleMs += ms
        _stats.outputWidth = CVPixelBufferGetWidth(out); _stats.outputHeight = CVPixelBufferGetHeight(out)
        upscaleBudget.record(costMs: ms, intervalMs: clockWatch.intervalMs, atMs: Self.nowMs())
        statLock.unlock()
        return out
    }
}

#if canImport(SwiftUI)
struct EnhanceSettingsSection: View {
    @AppStorage(EnhancePrefs.denoiseKey) private var denoise = false
    @AppStorage(EnhancePrefs.denoiseStrengthKey) private var strength = EnhancePrefs.defaultStrength
    @AppStorage(EnhancePrefs.upscaleKey) private var upscale = false
    @AppStorage(EnhancePrefs.upscaleFactorKey) private var factor = EnhancePrefs.defaultUpscaleFactor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Picture enhancement").font(.headline)
            if !EnhanceSupport.upscale {
                Text("Upscaling needs a Mac with Apple silicon.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Reduce noise (low light, high ISO)", isOn: $denoise).disabled(!EnhanceSupport.denoise)
            HStack {
                Text("Strength")
                Slider(value: $strength, in: 0...1).disabled(!denoise || !EnhanceSupport.denoise)
                Text(verbatim: "\(Int(strength * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Toggle("Upscale the picture", isOn: $upscale).disabled(!EnhanceSupport.upscale)
            Picker("Scale", selection: $factor) {
                Text(verbatim: "1.5x").tag(1.5)
                Text(verbatim: "2x").tag(2.0)
            }
            .pickerStyle(.segmented)
            .disabled(!upscale || !EnhanceSupport.upscale)
            Text("Reducing noise blends each picture with the ones before it, so a moving subject can leave a faint trail at high strength. Upscaling makes the picture larger and sharper with Apple's MetalFX scaler. The goggles still send 1080p, so it helps most for recordings and large displays; it does not add detail that was never captured. Both run on the GPU, add no frames of delay, switch themselves off when the Mac cannot keep up, and are off in race mode. They apply to the preview, recordings and streams.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
