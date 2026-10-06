import XCTest
import CoreImage
import CoreVideo
@testable import GogglesView

/// Synthetic-footage checks for the stabilizer: textured still + random-walk shake + slow pan.
final class StabilizerBenchmarkTests: XCTestCase {
    private let ci = CIContext()
    private let yuv8 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private let yuv10 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    private func makeBuffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, fmt,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        return b!
    }

    /// Textured still seen through a camera at `offset` (content moves by +offset).
    private func frame(_ w: Int, _ h: Int, _ fmt: OSType, offset: CGPoint) -> CVPixelBuffer {
        let b = makeBuffer(w, h, fmt)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        ci.render(noise, to: b, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return b
    }

    /// Measure on a 1280-wide copy and scale back.
    private func motion(_ a: CVPixelBuffer, _ b: CVPixelBuffer) throws -> CGPoint {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let k = 1280.0 / Double(w), sh = Int(Double(h) * k)
        func small(_ x: CVPixelBuffer) -> CVPixelBuffer {
            let o = makeBuffer(1280, sh, kCVPixelFormatType_32BGRA)
            ci.render(CIImage(cvPixelBuffer: x).transformed(by: CGAffineTransform(scaleX: k, y: k)), to: o)
            return o
        }
        let sa = small(a), sb = small(b)
        ci.clearCaches()   // the context otherwise keeps the source surfaces alive and starves the stabilizer's buffer pool
        let m = try XCTUnwrap(Stabilizer.measure(from: sa, to: sb))
        return CGPoint(x: m.x / k, y: m.y / k)
    }

    private struct Rng {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    }

    /// Camera offsets: bounded random-walk shake (about +-12 px) plus a steady pan.
    private func path(count: Int, pan: CGPoint, seed: UInt64 = 42) -> [CGPoint] {
        var r = Rng(s: seed); var sx = 0.0, sy = 0.0
        return (0..<count).map { i in
            sx = min(12, max(-12, sx * 0.8 + (r.next() - 0.5) * 12))
            sy = min(12, max(-12, sy * 0.8 + (r.next() - 0.5) * 12))
            return CGPoint(x: sx + pan.x * Double(i), y: sy + pan.y * Double(i))
        }
    }

    private func rms(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    private struct Result {
        var inShake: Double, outShake: Double, inTotal: CGPoint, outTotal: CGPoint
        var ms: Double, size: CGSize, fmt: OSType
    }

    private func run(_ w: Int, _ h: Int, _ fmt: OSType, frames n: Int = 90, strength: Double = 0.6,
                     pan: CGPoint = CGPoint(x: 1.5, y: 0.5)) throws -> Result {
        let st = Stabilizer()
        let offs = path(count: n, pan: pan)
        var prevIn: CVPixelBuffer?, prevOut: CVPixelBuffer?
        var inM = [CGPoint](), outM = [CGPoint]()
        var total = 0.0
        var last: CVPixelBuffer!
        for o in offs {
            let f = frame(w, h, fmt, offset: o)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let out = st.process(f, strength: strength)
            total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if let pi = prevIn, let po = prevOut {
                inM.append(try motion(pi, f))
                outM.append(try motion(po, out))
            }
            prevIn = f; prevOut = out; last = out
        }
        // Skip the warm-up frames; shake = deviation of per-frame motion from the (constant) pan.
        let a = Array(inM.dropFirst(10)), b = Array(outM.dropFirst(10))
        let inS = (rms(a.map { Double($0.x) }) + rms(a.map { Double($0.y) })) / 2
        let outS = (rms(b.map { Double($0.x) }) + rms(b.map { Double($0.y) })) / 2
        func sum(_ v: [CGPoint]) -> CGPoint { v.reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) } }
        return Result(inShake: inS, outShake: outS, inTotal: sum(inM), outTotal: sum(outM),
                      ms: total / Double(n), size: CGSize(width: CVPixelBufferGetWidth(last), height: CVPixelBufferGetHeight(last)),
                      fmt: CVPixelBufferGetPixelFormatType(last))
    }

    private func check(_ r: Result, _ w: Int, _ h: Int, _ fmt: OSType, label: String) {
        let reduction = 100 * (1 - r.outShake / r.inShake)
        print("[stab] \(label) \(w)x\(h): shake in \(String(format: "%.2f", r.inShake)) px out \(String(format: "%.2f", r.outShake)) px reduction \(String(format: "%.1f", reduction))% ms/frame \(String(format: "%.1f", r.ms)) pan in (\(r.inTotal.x), \(r.inTotal.y)) out (\(r.outTotal.x), \(r.outTotal.y))")
        XCTAssertEqual(r.size, CGSize(width: w, height: h))
        XCTAssertEqual(r.fmt, fmt)
        XCTAssertGreaterThanOrEqual(reduction, 50, label)
        // Pan still followed: net output motion tracks input, differing by no more than the margin.
        let margin = StabilizerPrefs.margin(forStrength: 0.6)
        XCTAssertLessThan(abs(r.outTotal.x - r.inTotal.x), margin * Double(w) * 1.2, label)
        XCTAssertLessThan(abs(r.outTotal.y - r.inTotal.y), margin * Double(h) * 1.2, label)
        XCTAssertGreaterThan(r.outTotal.x, r.inTotal.x * 0.8, "pan not followed \(label)")
        XCTAssertLessThan(r.ms, 100, label)
    }

    func testShakeReducedBGRA720() throws { check(try run(1280, 720, kCVPixelFormatType_32BGRA), 1280, 720, kCVPixelFormatType_32BGRA, label: "BGRA") }
    func testShakeReducedBGRA1080() throws { check(try run(1920, 1080, kCVPixelFormatType_32BGRA), 1920, 1080, kCVPixelFormatType_32BGRA, label: "BGRA") }
    func testShakeReduced420v720() throws { check(try run(1280, 720, yuv8), 1280, 720, yuv8, label: "420v") }
    func testShakeReduced420v1080() throws { check(try run(1920, 1080, yuv8), 1920, 1080, yuv8, label: "420v") }
    func testShakeReducedX420() throws { check(try run(1280, 720, yuv10), 1280, 720, yuv10, label: "x420") }

    func testNoDriftOnStillCamera() throws {
        let r = try run(1280, 720, kCVPixelFormatType_32BGRA, pan: .zero)
        XCTAssertLessThan(abs(r.outTotal.x), 25)
        XCTAssertLessThan(abs(r.outTotal.y), 25)
    }

    func testColourPreserved() throws {
        let probe = makeBuffer(64, 64, kCVPixelFormatType_32BGRA)
        func mean(_ b: CVPixelBuffer) -> [Double] {
            let img = CIImage(cvPixelBuffer: b)
            let e = img.extent
            let centre = img.cropped(to: e.insetBy(dx: e.width * 0.25, dy: e.height * 0.25))
                .transformed(by: CGAffineTransform(translationX: -e.width * 0.25, y: -e.height * 0.25))
            ci.render(centre.transformed(by: CGAffineTransform(scaleX: 64 / (e.width / 2), y: 64 / (e.height / 2))),
                      to: probe, bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            CVPixelBufferLockBaseAddress(probe, .readOnly); defer { CVPixelBufferUnlockBaseAddress(probe, .readOnly) }
            let p = CVPixelBufferGetBaseAddress(probe)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(probe)
            var s = [0.0, 0.0, 0.0]; var n = 0.0
            for y in 0..<64 { for x in 0..<64 {
                let q = p + y * bpr + x * 4
                s[0] += Double(q[2]); s[1] += Double(q[1]); s[2] += Double(q[0]); n += 1
            } }
            return s.map { $0 / n }
        }
        for fmt in [kCVPixelFormatType_32BGRA, yuv8, yuv10] {
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            let colour = CIImage(color: CIColor(red: 200.0 / 255, green: 100.0 / 255, blue: 50.0 / 255, colorSpace: sRGB)!)
            let src = makeBuffer(640, 360, fmt)
            ci.render(colour, to: src, bounds: CGRect(x: 0, y: 0, width: 640, height: 360), colorSpace: sRGB)
            let before = mean(src)
            let st = Stabilizer()
            var out = src
            for _ in 0..<3 { out = st.process(src, strength: 0.6) }
            let after = mean(out)
            print("[stab] colour fmt \(fmt) before \(before) after \(after)")
            for i in 0..<3 { XCTAssertEqual(after[i], before[i], accuracy: 4, "channel \(i) fmt \(fmt)") }
        }
    }
}
