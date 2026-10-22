import XCTest
import CoreImage
import CoreVideo
@testable import GogglesView

/// Regression checks for what the recorded-footage study (`StabHarness`, `--stab-file`) found. Synthetic frames only, no video files.
final class StabilizerRealFootageTests: XCTestCase {
    private let ci = CIContext()

    /// Textured still shifted by `shift` (content moves by +shift), with a static white overlay (OSD-like bars, crosshair) on top.
    private func frame(_ w: Int, _ h: Int, shift: CGPoint = .zero, overlay: Bool) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        var img = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            .transformed(by: CGAffineTransform(translationX: shift.x, y: shift.y))
        if overlay {
            let white = CIImage(color: .white)
            let W = Double(w), H = Double(h)
            for r in [CGRect(x: 0, y: H - 0.1 * H, width: W, height: 0.1 * H), CGRect(x: 0, y: 0, width: W, height: 0.1 * H),
                      CGRect(x: W / 2 - 30, y: H / 2 - 1, width: 60, height: 3), CGRect(x: W / 2 - 1, y: H / 2 - 30, width: 3, height: 60)] {
                img = white.cropped(to: r).composited(over: img)
            }
        }
        ci.render(img, to: b!, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return b!
    }

    func testTranslationModeMeasuresShiftDespiteStaticOverlay() throws {
        let st = Stabilizer()
        _ = st.process(frame(1280, 720, overlay: true), strength: 0.6, mode: .translation)
        _ = st.process(frame(1280, 720, shift: CGPoint(x: 14, y: -6), overlay: true), strength: 0.6, mode: .translation)
        let s = st.stats
        // the registration must see the picture move, not the static overlay (a whole-frame translational fit reported about half)
        let measured = s.meanMotionPx * Double(s.frames)
        XCTAssertGreaterThan(measured, 0.6 * hypot(14, -6), "measured \(measured)")
        XCTAssertEqual(s.measureFailures, 0)
    }

    func testTranslationModeUsesHomographyRegistration() throws {
        let a = frame(640, 360, overlay: false), b = frame(640, 360, shift: CGPoint(x: -11, y: 5), overlay: false)
        let m = try XCTUnwrap(Stabilizer.measure(from: a, to: b, mode: .translation))
        XCTAssertEqual(m.t.x, -11, accuracy: 1)
        XCTAssertEqual(m.t.y, 5, accuracy: 1)
        XCTAssertEqual(m.roll, 0, "translation mode never reports roll")
    }

    func testAnalysisROIAndWidthKeepOutputGeometry() {
        for (w, roi) in [(480, 0.7), (640, 1.0), (384, 0.5)] {
            let st = Stabilizer()
            st.tuning = StabilizerTuning(analysisWidth: w, analysisROI: roi)
            var out = frame(960, 540, overlay: false)
            for i in 0..<4 { out = st.process(frame(960, 540, shift: CGPoint(x: Double(i) * 3, y: 0), overlay: false), strength: 0.6, mode: .translation) }
            XCTAssertEqual(CVPixelBufferGetWidth(out), 960)
            XCTAssertEqual(CVPixelBufferGetHeight(out), 540)
            XCTAssertEqual(st.stats.measureFailures, 0, "width \(w) roi \(roi)")
        }
    }

    func testTilesModeSurvivesManyFrames() {
        // Concurrent tile registrations raced inside Vision (NSRangeException after about 1000 real frames); they run serially now.
        let st = Stabilizer()
        var x = 0.0
        for _ in 0..<150 { x += 2; _ = st.process(frame(640, 360, shift: CGPoint(x: x, y: 0), overlay: false), strength: 0.6, mode: .similarityTiles) }
        XCTAssertEqual(st.stats.frames, 150)
    }

    func testShakeMetricSeparatesJitterFromSlowPath() {
        let n = 200
        let jitter = (0..<n).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        XCTAssertEqual(StabMetrics.highpassRMS(path: jitter), 1, accuracy: 0.1)
        XCTAssertEqual(StabMetrics.highpassRMS(path: [Double](repeating: 7, count: n)), 0, accuracy: 1e-9)
        let slow = (0..<n).map { 40 * sin(Double($0) / 60) }
        XCTAssertLessThan(StabMetrics.highpassRMS(path: slow), 0.5)
        // per-frame motions in, same measure out: a path that only jitters has the same shake as its jitter
        let dx = zip(jitter.dropFirst(), jitter).map { $0 - $1 }
        XCTAssertEqual(StabMetrics.highpassRMS2D(dx: dx, dy: [Double](repeating: 0, count: dx.count)), 1, accuracy: 0.15)
        XCTAssertEqual(StabMetrics.cumulative([1, 2, 3]), [1, 3, 6])
    }
}
