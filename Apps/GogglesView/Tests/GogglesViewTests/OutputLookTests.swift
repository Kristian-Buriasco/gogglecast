import XCTest
import CoreImage
import CoreVideo
@testable import GogglesView

final class OutputLookTests: XCTestCase {
    private func identityCube(size n: Int, title: String = "t") -> String {
        var s = "TITLE \"\(title)\"\n# comment\nLUT_3D_SIZE \(n)\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            s += "\(Float(r) / Float(n - 1)) \(Float(g) / Float(n - 1)) \(Float(b) / Float(n - 1))\n"
        } } }
        return s
    }

    func testParsesIdentityCube() throws {
        let lut = try CubeLUT.parse(identityCube(size: 4))
        XCTAssertEqual(lut.size, 4)
        XCTAssertEqual(lut.rgba.count, 4 * 4 * 4 * 4)
        // Second entry is red index 1 -> r = 1/3
        XCTAssertEqual(lut.rgba[4], 1.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(lut.rgba[7], 1)
    }

    func testDomainIsNormalized() throws {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n" +
            (0..<8).map { _ in "2 1 0" }.joined(separator: "\n")
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(Array(lut.rgba[0..<3]), [1, 0.5, 0])
    }

    func testRejectsBadFiles() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        XCTAssertThrowsError(try CubeLUT.parse("hello"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 x\n"))
    }

    func testIntensityBlendsTowardIdentity() throws {
        // A cube that maps everything to white.
        let white = "LUT_3D_SIZE 2\n" + (0..<8).map { _ in "1 1 1" }.joined(separator: "\n")
        let lut = try CubeLUT.parse(white)
        func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        XCTAssertEqual(floats(lut.cubeData(intensity: 1))[0], 1)
        XCTAssertEqual(floats(lut.cubeData(intensity: 0))[0], 0)          // black stays black
        XCTAssertEqual(floats(lut.cubeData(intensity: 0.5))[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(floats(lut.cubeData(intensity: 0)).count, 8 * 4)
    }

    func testLibraryImportListRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luts-\(UUID().uuidString)")
        let saved = LUTLibrary.directory
        LUTLibrary.directory = dir
        defer { LUTLibrary.directory = saved; try? FileManager.default.removeItem(at: dir) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("Warm.cube")
        try identityCube(size: 3).write(to: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LUTLibrary.importFile(src), "Warm")
        XCTAssertEqual(LUTLibrary.names(), ["Warm"])
        XCTAssertNotNil(LUTLibrary.load("Warm"))
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("Bad.cube")
        try "nope".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LUTLibrary.importFile(bad))
        LUTLibrary.remove("Warm")
        XCTAssertEqual(LUTLibrary.names(), [])
    }

    func testGeometryAspectAndZoom() {
        let full = OutputGeometry.plan(size: CGSize(width: 1920, height: 1080), ratio: nil, zoom: 1, panX: 0, panY: 0)
        XCTAssertEqual(full.rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(full.out, CGSize(width: 1920, height: 1080))

        let square = OutputGeometry.plan(size: CGSize(width: 1920, height: 1080), ratio: 1, zoom: 1, panX: 0, panY: 0)
        XCTAssertEqual(square.out, CGSize(width: 1080, height: 1080))
        XCTAssertEqual(square.rect.minX, 420)

        let vertical = OutputGeometry.plan(size: CGSize(width: 1920, height: 1080), ratio: 9.0 / 16, zoom: 1, panX: 0, panY: 0)
        XCTAssertEqual(vertical.out.height, 1080)
        XCTAssertEqual(vertical.out.width, 606)   // 607.5 rounded down to even

        let zoomed = OutputGeometry.plan(size: CGSize(width: 1920, height: 1080), ratio: nil, zoom: 2, panX: 1, panY: -1)
        XCTAssertEqual(zoomed.out, CGSize(width: 1920, height: 1080))   // size unchanged, content scaled up
        XCTAssertEqual(zoomed.rect, CGRect(x: 960, y: 0, width: 960, height: 540))   // right edge, bottom edge
        let noPan = OutputGeometry.plan(size: CGSize(width: 1920, height: 1080), ratio: nil, zoom: 1, panX: 1, panY: 1)
        XCTAssertEqual(noPan.rect.minX, 0)   // pan ignored at zoom 1
    }

    func testProcessorCropsToSquareAndSkipsUnchangedFrames() throws {
        let d = UserDefaults.standard
        let keys = [OutputFramingPrefs.enabledKey, OutputFramingPrefs.aspectKey, OutputFramingPrefs.zoomKey, LookPrefs.nameKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.set(true, forKey: OutputFramingPrefs.enabledKey)
        d.set(FramingAspect.r1x1.rawValue, forKey: OutputFramingPrefs.aspectKey)
        d.set(1.0, forKey: OutputFramingPrefs.zoomKey)
        d.removeObject(forKey: LookPrefs.nameKey)

        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        let p = OutputProcessor()
        XCTAssertTrue(OutputProcessor.isActive)
        let out = try XCTUnwrap(p.process(b!))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 360)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 360)
        XCTAssertNil(p.process(b!), "same IOSurface contents must not be processed twice")

        d.set(false, forKey: OutputFramingPrefs.enabledKey)
        XCTAssertFalse(OutputProcessor.isActive)
        XCTAssertTrue(p.process(b!) === b!)
    }
}
