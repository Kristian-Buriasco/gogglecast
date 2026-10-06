import XCTest
import CoreImage
import CoreVideo
@testable import GogglesView

final class StabilizerTests: XCTestCase {
    private let ci = CIContext()

    private func buffer(width: Int, height: Int, shift: CGPoint = .zero, format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 3, y: 3))
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: shift.x, y: shift.y))
        ci.render(noise, to: b!, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return b!
    }

    func testMeasureReportsContentMotion() throws {
        let a = buffer(width: 320, height: 180)
        let b = buffer(width: 320, height: 180, shift: CGPoint(x: 9, y: -4))
        let m = try XCTUnwrap(Stabilizer.measure(from: a, to: b))
        XCTAssertEqual(m.x, 9, accuracy: 1.5)
        XCTAssertEqual(m.y, -4, accuracy: 1.5)
    }

    func testSmootherRemovesJitterButFollowsPan() {
        var s = PathSmoother(strength: 0.8)
        let limit = CGSize(width: 1000, height: 1000)
        var worst: CGFloat = 0
        // Alternating +10/-10 jitter: corrected position must stay near zero shake.
        for i in 0..<200 {
            let c = s.step(motion: CGPoint(x: i % 2 == 0 ? 10 : -10, y: 0), limit: limit)
            if i > 20 { worst = max(worst, abs(s.path.x + c.x - s.smooth.x)) }
        }
        XCTAssertLessThan(worst, 0.001)
        XCTAssertLessThan(abs(s.smooth.x), 12)
        // Steady pan: smoothed path converges to the real path (bounded lag).
        var p = PathSmoother(strength: 0.5)
        var c = CGPoint.zero
        for _ in 0..<200 { c = p.step(motion: CGPoint(x: 2, y: 0), limit: limit) }
        XCTAssertEqual(abs(c.x), 2 * 0.74 / 0.26, accuracy: 0.2) // steady-state lag = v*a/(1-a)
    }

    func testSmootherClampsCorrection() {
        var s = PathSmoother(strength: 1)
        var c = CGPoint.zero
        for _ in 0..<100 { c = s.step(motion: CGPoint(x: 30, y: 0), limit: CGSize(width: 20, height: 20)) }
        XCTAssertEqual(abs(c.x), 20, accuracy: 0.001)
    }

    func testProcessKeepsSizeAndFormat() {
        let st = Stabilizer()
        let a = buffer(width: 640, height: 360)
        let out1 = st.process(a, strength: 0.6)
        let out2 = st.process(buffer(width: 640, height: 360, shift: CGPoint(x: 12, y: 3)), strength: 0.6)
        for o in [out1, out2] {
            XCTAssertEqual(CVPixelBufferGetWidth(o), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(o), 360)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(o), kCVPixelFormatType_32BGRA)
        }
        XCTAssertNotNil(st.costMs)
    }

    func testDisabledPassesThroughSameBuffer() {
        UserDefaults.standard.set(false, forKey: StabilizerPrefs.enabledKey)
        let a = buffer(width: 320, height: 180)
        XCTAssertTrue(Stabilizer().process(a) === a)
    }
}
