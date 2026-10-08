import Testing
import Foundation
import CoreVideo
import CoreGraphics
@testable import GogglesView

@Suite struct ExposureAssistTests {
    private func frame(width: Int, height: Int, _ f: (Int, Int) -> UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v = f(x, y), o = (y * width + x) * 4
            px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
        } }
        return px
    }

    private func overlay(_ px: [UInt8], w: Int, h: Int, _ s: ExposureSettings) -> [UInt8] {
        px.withUnsafeBufferPointer {
            ExposureAnalysis.overlay(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, settings: s)
        }
    }

    private func alpha(_ o: [UInt8], w: Int, x: Int, y: Int) -> UInt8 { o[(y * w + x) * 4 + 3] }

    @Test func zebraMarksOnlyBrightPixels() {
        let w = 32, h = 8
        let px = frame(width: w, height: h) { x, _ in x < 16 ? 100 : 255 }
        let s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: false, sensitivity: .medium, color: .red)
        let o = overlay(px, w: w, h: h, s)
        for y in 0..<h { for x in 0..<16 { #expect(alpha(o, w: w, x: x, y: y) == 0) } }
        for y in 0..<h { for x in 16..<w { #expect(alpha(o, w: w, x: x, y: y) > 0) } }
    }

    @Test func zebraLevelMovesTheThreshold() {
        let w = 8, h = 8
        let px = frame(width: w, height: h) { _, _ in 200 } // 78%
        var s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: false, sensitivity: .medium, color: .red)
        #expect(overlay(px, w: w, h: h, s).allSatisfy { $0 == 0 })
        s.zebraLevel = 70
        #expect(overlay(px, w: w, h: h, s).contains { $0 != 0 })
    }

    @Test func clippingLevelNeedsNearWhite() {
        #expect(ExposureAnalysis.zebraThreshold(level: 100) > 0.95)
        #expect(ExposureAnalysis.zebraThreshold(level: 70) == 0.70)
    }

    @Test func zebraStripesAlternateDarkAndLight() {
        let w = 32, h = 8
        let px = frame(width: w, height: h) { _, _ in 255 }
        let s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: false, sensitivity: .medium, color: .red)
        let o = overlay(px, w: w, h: h, s)
        let colours = Set((0..<w).map { o[(0 * w + $0) * 4] })
        #expect(colours == [0, 200])
    }

    @Test func peakingFindsEdgesNotFlatAreas() {
        let w = 32, h = 16
        let px = frame(width: w, height: h) { x, _ in x < 16 ? 30 : 220 }
        let s = ExposureSettings(zebra: false, zebraLevel: 95, peaking: true, sensitivity: .medium, color: .green)
        let o = overlay(px, w: w, h: h, s)
        #expect(alpha(o, w: w, x: 15, y: 8) == 255)
        #expect(alpha(o, w: w, x: 16, y: 8) == 255)
        #expect(alpha(o, w: w, x: 4, y: 8) == 0)
        #expect(alpha(o, w: w, x: 28, y: 8) == 0)
        // Green in BGRA.
        #expect(o[(8 * w + 15) * 4 + 1] == 255)
    }

    @Test func peakingSensitivityOrdersThresholds() {
        let w = 16, h = 8
        // Soft edge: gradient 0.4 per step.
        let px = frame(width: w, height: h) { x, _ in x < 8 ? 100 : 160 }
        func count(_ sens: PeakingSensitivity) -> Int {
            let s = ExposureSettings(zebra: false, zebraLevel: 95, peaking: true, sensitivity: sens, color: .red)
            return stride(from: 3, to: overlay(px, w: w, h: h, s).count, by: 4).filter { overlay(px, w: w, h: h, s)[$0] > 0 }.count
        }
        #expect(count(.low) <= count(.medium))
        #expect(count(.medium) <= count(.high))
        #expect(count(.high) > 0)
    }

    @Test func peakingWinsOverZebraOnTheSamePixel() {
        let w = 16, h = 8
        let px = frame(width: w, height: h) { x, _ in x < 8 ? 0 : 255 }
        let s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: true, sensitivity: .medium, color: .red)
        let o = overlay(px, w: w, h: h, s)
        #expect(o[(4 * w + 8) * 4 + 2] == 255) // red channel of the edge pixel
    }

    @Test func tinyFramesDoNotCrash() {
        let s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: true, sensitivity: .high, color: .white)
        #expect(overlay(frame(width: 2, height: 2) { _, _ in 255 }, w: 2, h: 2, s).count == 16)
    }

    @Test func preferencesDefaultOffAndRaceModeSilencesThem() {
        let d = UserDefaults(suiteName: "exposure-test-\(UUID().uuidString)")!
        #expect(ExposurePrefs.current(raceMode: false, defaults: d) == nil)
        d.set(true, forKey: ExposurePrefs.zebraKey)
        d.set(80, forKey: ExposurePrefs.zebraLevelKey)
        let on = ExposurePrefs.current(raceMode: false, defaults: d)
        #expect(on?.zebra == true && on?.zebraLevel == 80 && on?.peaking == false)
        #expect(ExposurePrefs.current(raceMode: true, defaults: d) == nil)
        d.set(5, forKey: ExposurePrefs.zebraLevelKey)
        #expect(ExposurePrefs.zebraLevel(d) == 50)
    }

    @Test func analyzerProducesAnOverlayImageAndClearsWhenOff() async {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buf)
        let b = buf!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b)!, 255, CVPixelBufferGetBytesPerRow(b) * 1080)
        CVPixelBufferUnlockBaseAddress(b, [])
        let analyzer = ExposureAnalyzer()
        let s = ExposureSettings(zebra: true, zebraLevel: 95, peaking: false, sensitivity: .medium, color: .red)
        let got: CGImage? = await withCheckedContinuation { c in
            analyzer.submit(b, settings: s) { c.resume(returning: $0) }
        }
        #expect(got?.width == ExposureAnalysis.analysisWidth)
        #expect(got?.height == 360)
        let cleared: Bool = await withCheckedContinuation { c in
            analyzer.submit(b, settings: nil) { c.resume(returning: $0 == nil) }
        }
        #expect(cleared)
    }
}
