import Foundation
import CoreImage
import CoreVideo
import Vision
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Live electronic stabilization of the decoded picture.
///
/// Causal by design: each frame is corrected using only the motion seen so far (no look-ahead
/// buffer), so it adds processing time (a few ms) but no frames of delay. It removes shake, not
/// slow pans, by low-pass filtering the cumulative camera path and shifting the frame by the
/// difference. A small zoom hides the edges the shift would otherwise reveal.
enum StabilizerPrefs {
    static let enabledKey = "stabilizeEnabled"
    static let strengthKey = "stabilizeStrength"
    static let defaultStrength = 0.6

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var strength: Double {
        let v = UserDefaults.standard.object(forKey: strengthKey) as? Double ?? defaultStrength
        return min(max(v, 0), 1)
    }

    /// Fraction of each edge reserved for the correction (the zoom that hides it): 4% to 10%.
    static func margin(forStrength s: Double) -> Double { 0.04 + 0.06 * min(max(s, 0), 1) }
}

/// Low-pass filter of the cumulative camera path. Pure math, no images.
struct PathSmoother {
    var strength: Double
    private(set) var path = CGPoint.zero
    private(set) var smooth = CGPoint.zero

    init(strength: Double) { self.strength = strength }

    /// `motion` is how far the picture content moved since the previous frame; `limit` is the
    /// largest correction that can be shown without revealing the frame edge. Returns the shift to
    /// apply to the current frame so its content sits where the smoothed path says it should.
    mutating func step(motion: CGPoint, limit: CGSize) -> CGPoint {
        path.x += motion.x; path.y += motion.y
        let alpha = CGFloat(0.5 + 0.48 * min(max(strength, 0), 1))
        smooth.x = alpha * smooth.x + (1 - alpha) * path.x
        smooth.y = alpha * smooth.y + (1 - alpha) * path.y
        var c = CGPoint(x: smooth.x - path.x, y: smooth.y - path.y)
        // Past the limit the smoothed path is dragged along so the picture follows a real pan.
        if abs(c.x) > limit.width { c.x = c.x < 0 ? -limit.width : limit.width; smooth.x = path.x + c.x }
        if abs(c.y) > limit.height { c.y = c.y < 0 ? -limit.height : limit.height; smooth.y = path.y + c.y }
        return c
    }

    mutating func reset() { path = .zero; smooth = .zero }
}

final class Stabilizer {
    private let lock = NSLock()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var smoother = PathSmoother(strength: StabilizerPrefs.defaultStrength)
    private var previousSmall: CVPixelBuffer?
    private var outPool: CVPixelBufferPool?
    private var smallPool: CVPixelBufferPool?
    private var poolKey: (w: Int, h: Int, fmt: OSType)?
    private static let analysisWidth = 384

    /// Smoothed time spent per frame, for diagnostics.
    private(set) var costMs: Double?

    /// Returns a stabilized copy of `input`, or `input` itself when off or when anything fails.
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer {
        guard StabilizerPrefs.enabled else {
            lock.lock(); if previousSmall != nil { previousSmall = nil; smoother.reset() }; lock.unlock()
            return input
        }
        return process(input, strength: StabilizerPrefs.strength)
    }

    func process(_ input: CVPixelBuffer, strength: Double) -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        let start = DispatchTime.now().uptimeNanoseconds
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        guard w > 64, h > 64 else { return input }
        let fmt = CVPixelBufferGetPixelFormatType(input)
        if poolKey?.w != w || poolKey?.h != h || poolKey?.fmt != fmt {
            makePools(w: w, h: h, fmt: fmt)
            previousSmall = nil
            smoother.reset()
        }
        smoother.strength = strength
        guard let outPool, let smallPool,
              let small = makeBuffer(from: smallPool),
              let out = makeBuffer(from: outPool) else { return input }

        let scale = CGFloat(Self.analysisWidth) / CGFloat(w)
        let image = CIImage(cvPixelBuffer: input)
        ci.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: small)

        var motion = CGPoint.zero
        if let prev = previousSmall, let m = Stabilizer.measure(from: prev, to: small) {
            motion = CGPoint(x: m.x / scale, y: m.y / scale)
        }
        previousSmall = small

        let margin = CGFloat(StabilizerPrefs.margin(forStrength: strength))
        let c = smoother.step(motion: motion, limit: CGSize(width: margin * CGFloat(w), height: margin * CGFloat(h)))
        let zoom = 1 / (1 - 2 * margin)
        let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        ci.render(image.transformed(by: t), to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        copyAttachments(from: input, to: out)

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        costMs = costMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
        return out
    }

    /// How far the content of `to` moved relative to `from`, in pixels of those buffers (y up).
    static func measure(from: CVPixelBuffer, to: CVPixelBuffer) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: to)
        let handler = VNImageRequestHandler(cvPixelBuffer: from, options: [:])
        guard (try? handler.perform([request])) != nil,
              let r = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        // The transform aligns `to` back onto `from`, i.e. it is the opposite of the content motion.
        return CGPoint(x: -r.alignmentTransform.tx, y: -r.alignmentTransform.ty)
    }

    private func makePools(w: Int, h: Int, fmt: OSType) {
        func pool(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBufferPool? {
            var p: CVPixelBufferPool?
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: fmt,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            return p
        }
        let sw = Self.analysisWidth, sh = max(2, Int((Double(h) / Double(w) * Double(sw)).rounded()))
        outPool = pool(w, h, fmt)
        smallPool = pool(sw, sh, kCVPixelFormatType_32BGRA)
        poolKey = (w, h, fmt)
    }

    private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 8]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux as CFDictionary, &b) == kCVReturnSuccess else { return nil }
        return b
    }

    private func copyAttachments(from a: CVPixelBuffer, to b: CVPixelBuffer) {
        if let atts = CVBufferCopyAttachments(a, .shouldPropagate) {
            CVBufferSetAttachments(b, atts, .shouldPropagate)
        }
    }
}

#if canImport(SwiftUI)
struct StabilizerSettingsSection: View {
    @AppStorage(StabilizerPrefs.enabledKey) private var enabled = false
    @AppStorage(StabilizerPrefs.strengthKey) private var strength = StabilizerPrefs.defaultStrength

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live stabilization").font(.headline)
            Toggle("Stabilize the live picture", isOn: $enabled)
            HStack {
                Text("Strength")
                Slider(value: $strength, in: 0...1).disabled(!enabled)
                Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Text("Electronic stabilization: removes shake from the picture without waiting for future frames, so it adds processing time (a few ms) but no frames of delay. It zooms in 4 to 10% to hide the edges, doesn't correct rotation, and applies to recordings and streams made from the live picture. Stronger = smoother but a little more lag on real pans.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
