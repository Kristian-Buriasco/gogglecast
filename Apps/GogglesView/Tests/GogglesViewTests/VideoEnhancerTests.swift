import XCTest
import CoreImage
import CoreVideo
import CoreMedia
@testable import GogglesView

final class VideoEnhancerTests: XCTestCase {
    func testDenoiseParametersGrowWithStrength() {
        let lo = CITemporalDenoiser.parameters(strength: 0), hi = CITemporalDenoiser.parameters(strength: 1)
        XCTAssertLessThan(lo.weight, hi.weight)
        XCTAssertLessThan(lo.threshold, hi.threshold)
        XCTAssertLessThanOrEqual(hi.weight, 0.9, "never freeze the picture")
        let clamped = CITemporalDenoiser.parameters(strength: 9)
        XCTAssertEqual(clamped.weight, hi.weight)
    }

    func testPrefsDefaultOffAndClamp() {
        let d = UserDefaults.standard
        let keys = [EnhancePrefs.denoiseKey, EnhancePrefs.upscaleKey, EnhancePrefs.denoiseStrengthKey, EnhancePrefs.upscaleFactorKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        keys.forEach { d.removeObject(forKey: $0) }
        XCTAssertFalse(EnhancePrefs.denoise)
        XCTAssertFalse(EnhancePrefs.upscale)
        XCTAssertFalse(EnhancePrefs.anyEnabled)
        XCTAssertEqual(EnhancePrefs.denoiseStrength, 0.5)
        d.set(7.0, forKey: EnhancePrefs.denoiseStrengthKey)
        XCTAssertEqual(EnhancePrefs.denoiseStrength, 1)
        d.set(0.0, forKey: EnhancePrefs.upscaleFactorKey)
        XCTAssertEqual(EnhancePrefs.upscaleFactor, EnhancePrefs.defaultUpscaleFactor)
    }

    func testDisabledEnhancerPassesThePictureThrough() {
        let d = UserDefaults.standard
        d.removeObject(forKey: EnhancePrefs.denoiseKey); d.removeObject(forKey: EnhancePrefs.upscaleKey)
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &b)
        let e = VideoEnhancer()
        let t = CMTime(value: 1, timescale: 30)
        XCTAssertTrue(e.denoise(b!, pts: t) === b!)
        XCTAssertTrue(e.upscale(b!, pts: t) === b!)
    }

    // MARK: needs macOS 26 and a supporting Mac; skipped elsewhere

    private let ci = CIContext()

    private func noisyFrame(_ w: Int, _ h: Int, seed: Int, amplitude: CGFloat = 0.10) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &b)
        let flat = CIImage(color: CIColor(red: 0.4, green: 0.45, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // fresh noise every frame: seed shifts the generator's output
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: CGFloat(seed * 977), y: CGFloat(seed * 613)))
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: amplitude, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: amplitude, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: amplitude, w: 0), "inputBiasVector": CIVector(x: -amplitude / 2, y: -amplitude / 2, z: -amplitude / 2, w: 0)])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        ci.render(noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: flat]), to: b!)
        return b!
    }

    /// Mean absolute difference between the luma of two same-sized pictures (a noise measure on a still scene).
    private func meanAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        func bgra(_ x: CVPixelBuffer) -> [UInt8] {
            var buf = x
            if CVPixelBufferGetPixelFormatType(x) != kCVPixelFormatType_32BGRA {
                var o: CVPixelBuffer?
                CVPixelBufferCreate(nil, CVPixelBufferGetWidth(x), CVPixelBufferGetHeight(x), kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &o)
                ci.render(CIImage(cvPixelBuffer: x), to: o!)
                buf = o!
            }
            CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            let n = CVPixelBufferGetBytesPerRow(buf) * CVPixelBufferGetHeight(buf)
            return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self), count: n))
        }
        let x = bgra(a), y = bgra(b)
        var sum = 0.0
        let n = min(x.count, y.count)
        for i in stride(from: 0, to: n, by: 4) { sum += abs(Double(x[i + 1]) - Double(y[i + 1])) }
        return sum / Double(n / 4)
    }

    func testDenoiseReducesFrameToFrameNoiseOnAStillScene() throws {
        guard EnhanceSupport.denoise else { throw XCTSkip("no noise reducer available") }
        let d = UserDefaults.standard
        d.set(true, forKey: EnhancePrefs.denoiseKey); d.set(1.0, forKey: EnhancePrefs.denoiseStrengthKey)
        defer { d.removeObject(forKey: EnhancePrefs.denoiseKey); d.removeObject(forKey: EnhancePrefs.denoiseStrengthKey) }
        let e = VideoEnhancer()
        var inputs: [CVPixelBuffer] = [], outputs: [CVPixelBuffer] = []
        for i in 0..<14 {
            let f = noisyFrame(1280, 720, seed: i)
            let t = CMTime(value: Int64(i), timescale: 30)
            e.noteTimestamp(Int64(i) * 33_333_333)
            inputs.append(f); outputs.append(e.denoise(f, pts: t))
        }
        XCTAssertEqual(e.stats.denoised, 14, "every frame went through the filter, last error: \(e.lastError ?? "none")")
        // compare the last frames, after the filter had references to blend with
        let before = (10..<13).map { meanAbsDiff(inputs[$0], inputs[$0 + 1]) }.reduce(0, +) / 3
        let after = (10..<13).map { meanAbsDiff(outputs[$0], outputs[$0 + 1]) }.reduce(0, +) / 3
        print("[denoise-test] noise between frames: \(String(format: "%.2f", before)) in, \(String(format: "%.2f", after)) out (\(Int((1 - after / before) * 100))% less)")
        XCTAssertGreaterThan(before, 3, "the synthetic frames really are noisy")
        XCTAssertLessThan(after, before * 0.8, "noise between frames: \(before) in, \(after) out")
    }

    func testUpscaleMakesTheFrameLarger() throws {
        guard EnhanceSupport.upscale else { throw XCTSkip("MetalFX spatial scaling not supported here") }
        let d = UserDefaults.standard
        d.set(true, forKey: EnhancePrefs.upscaleKey); d.set(2.0, forKey: EnhancePrefs.upscaleFactorKey)
        defer { d.removeObject(forKey: EnhancePrefs.upscaleKey); d.removeObject(forKey: EnhancePrefs.upscaleFactorKey) }
        let e = VideoEnhancer()
        let out = e.upscale(noisyFrame(960, 540, seed: 1), pts: CMTime(value: 1, timescale: 30))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 1920, "last error: \(e.lastError ?? "none")")
        XCTAssertEqual(CVPixelBufferGetHeight(out), 1080)
    }

    func testDenoiseSweepReport() throws {
        guard EnhanceSupport.denoise else { throw XCTSkip("no noise reducer available") }
        let d = UserDefaults.standard
        d.set(true, forKey: EnhancePrefs.denoiseKey)
        defer { d.removeObject(forKey: EnhancePrefs.denoiseKey); d.removeObject(forKey: EnhancePrefs.denoiseStrengthKey) }
        for amplitude in [CGFloat(0.06), 0.10, 0.20] {
            for strength in [0.3, 0.6, 1.0] {
                d.set(strength, forKey: EnhancePrefs.denoiseStrengthKey)
                let e = VideoEnhancer()
                var ins: [CVPixelBuffer] = [], outs: [CVPixelBuffer] = []
                for i in 0..<20 {
                    let f = noisyFrame(960, 540, seed: i, amplitude: amplitude)
                    e.noteTimestamp(Int64(i) * 33_333_333)
                    ins.append(f); outs.append(e.denoise(f, pts: CMTime(value: Int64(i), timescale: 30)))
                }
                let before = (14..<19).map { meanAbsDiff(ins[$0], ins[$0 + 1]) }.reduce(0, +) / 5
                let after = (14..<19).map { meanAbsDiff(outs[$0], outs[$0 + 1]) }.reduce(0, +) / 5
                print("[denoise-sweep] noise amp \(amplitude) strength \(strength): \(String(format: "%.2f", before)) -> \(String(format: "%.2f", after)) (\(Int((1 - after / before) * 100))% less)")
            }
        }
    }

    /// A bright block moving across a noisy still background. The pixels the block has just left must not keep a
    /// trail of it: with a recursive filter that is the failure to watch for.
    func testDenoiseDoesNotLeaveATrailBehindMovingSubjects() throws {
        guard EnhanceSupport.denoise else { throw XCTSkip("no noise reducer available") }
        let d = UserDefaults.standard
        d.set(true, forKey: EnhancePrefs.denoiseKey)
        defer { d.removeObject(forKey: EnhancePrefs.denoiseKey); d.removeObject(forKey: EnhancePrefs.denoiseStrengthKey) }
        let w = 960, h = 540, block = 120, step = 24
        for strength in [0.5, 1.0] {
            d.set(strength, forKey: EnhancePrefs.denoiseStrengthKey)
            let e = VideoEnhancer()
            var lastOut: CVPixelBuffer?
            var lastIn: CVPixelBuffer?
            for i in 0..<16 {
                let bg = CIImage(cvPixelBuffer: noisyFrame(w, h, seed: i, amplitude: 0.06))
                let x = 100 + i * step
                let box = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: CGRect(x: x, y: 200, width: block, height: block))
                var frame: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &frame)
                ci.render(box.composited(over: bg), to: frame!)
                e.noteTimestamp(Int64(i) * 33_333_333)
                lastOut = e.denoise(frame!, pts: CMTime(value: Int64(i), timescale: 30))
                lastIn = frame
            }
            func regionMean(_ buf: CVPixelBuffer) -> Double {
                var probe: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &probe)
                ci.render(CIImage(cvPixelBuffer: buf), to: probe!)
                CVPixelBufferLockBaseAddress(probe!, .readOnly); defer { CVPixelBufferUnlockBaseAddress(probe!, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(probe!)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRow(probe!)
                var sum = 0.0, count = 0
                for y in stride(from: 230, to: 320, by: 3) { for x in stride(from: 110, to: 290, by: 3) { sum += Double(base[y * rowBytes + x * 4 + 1]); count += 1 } }
                return sum / Double(count)
            }
            let inMean = regionMean(lastIn!), outMean = regionMean(lastOut!)
            print("[denoise-trail] strength \(strength): region mean input \(String(format: "%.1f", inMean)), output \(String(format: "%.1f", outMean))")
            XCTAssertLessThan(outMean - inMean, 8, "trail left behind at strength \(strength): input \(inMean), output \(outMean)")
            continue
            // the block started at x=100 and ends the run at x = 100 + 15*24 = 460; the area it crossed early on
            // (x 100..300) must be background again, mean about the flat background value (0.4..0.5 of 255)
            let out = lastOut!
            var probe: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &probe)
            ci.render(CIImage(cvPixelBuffer: out), to: probe!)
            CVPixelBufferLockBaseAddress(probe!, .readOnly); defer { CVPixelBufferUnlockBaseAddress(probe!, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(probe!)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(probe!)
            var sum = 0.0, count = 0
            for y in stride(from: 210, to: 300, by: 3) { for x in stride(from: 110, to: 290, by: 3) { sum += Double(base[y * rowBytes + x * 4 + 1]); count += 1 } }
            let mean = sum / Double(count)
            print("[denoise-trail] strength \(strength): mean green where the block was 8+ frames ago: \(String(format: "%.0f", mean)) (background about 110, block 242)")
            XCTAssertLessThan(mean, 140, "trail left behind at strength \(strength)")
        }
    }

    /// Cost per frame at 1080p, and with several streams at once (the several-goggles case). Prints; asserts only
    /// that a single stream fits well inside a 30 fps frame interval.
    func testEnhancerCostAt1080p() throws {
        guard EnhanceSupport.denoise, EnhanceSupport.upscale else { throw XCTSkip("needs both stages") }
        let d = UserDefaults.standard
        d.set(true, forKey: EnhancePrefs.denoiseKey); d.set(true, forKey: EnhancePrefs.upscaleKey)
        d.set(0.6, forKey: EnhancePrefs.denoiseStrengthKey); d.set(2.0, forKey: EnhancePrefs.upscaleFactorKey)
        defer { for k in [EnhancePrefs.denoiseKey, EnhancePrefs.upscaleKey, EnhancePrefs.denoiseStrengthKey, EnhancePrefs.upscaleFactorKey] { d.removeObject(forKey: k) } }
        let frames = (0..<8).map { noisyFrame(1920, 1080, seed: $0, amplitude: 0.08) }
        func run(streams: Int, count: Int) -> (denoise: Double, upscale: Double, failures: Int) {
            let enhancers = (0..<streams).map { _ in VideoEnhancer() }
            DispatchQueue.concurrentPerform(iterations: streams) { s in
                let e = enhancers[s]
                for i in 0..<count {
                    let t = CMTime(value: Int64(i), timescale: 30)
                    e.noteTimestamp(Int64(i) * 33_333_333)
                    _ = e.upscale(e.denoise(frames[i % frames.count], pts: t), pts: t)
                }
            }
            let st = enhancers.map(\.stats)
            return (st.map(\.meanDenoiseMs).reduce(0, +) / Double(streams), st.map(\.meanUpscaleMs).reduce(0, +) / Double(streams), st.map(\.failures).reduce(0, +))
        }
        _ = run(streams: 1, count: 6)  // warm up (pipeline compilation)
        for streams in [1, 3] {
            let r = run(streams: streams, count: 60)
            print("[enhance-cost] 1080p, \(streams) stream(s): denoise \(String(format: "%.1f", r.denoise)) ms, upscale to 4K \(String(format: "%.1f", r.upscale)) ms per frame, failures \(r.failures)")
            if streams == 1 { XCTAssertLessThan(r.denoise + r.upscale, 33, "one stream must fit a 30 fps interval") }
        }
    }
}
