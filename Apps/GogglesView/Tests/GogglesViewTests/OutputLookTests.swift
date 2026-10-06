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

    // MARK: zoom render

    private func gradientBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        let buf = b!
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height { for x in 0..<width {
            let o = y * stride + x * 4
            base[o] = 0; base[o + 1] = 0; base[o + 2] = UInt8(x); base[o + 3] = 255 // BGRA: red = column
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func red(_ buf: CVPixelBuffer, x: Int, y: Int) -> Int {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        return Int(base[y * CVPixelBufferGetBytesPerRow(buf) + x * 4 + 2])
    }

    func testZoomIsCentredAndMapsEdgesToTheRightSourceColumns() throws {
        let d = UserDefaults.standard
        let keys = [OutputFramingPrefs.enabledKey, OutputFramingPrefs.aspectKey, OutputFramingPrefs.zoomKey,
                    OutputFramingPrefs.panXKey, OutputFramingPrefs.panYKey, LookPrefs.nameKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.set(true, forKey: OutputFramingPrefs.enabledKey)
        d.set(FramingAspect.fit.rawValue, forKey: OutputFramingPrefs.aspectKey)
        d.set(2.0, forKey: OutputFramingPrefs.zoomKey)
        d.set(0.0, forKey: OutputFramingPrefs.panXKey)
        d.set(0.0, forKey: OutputFramingPrefs.panYKey)
        d.removeObject(forKey: LookPrefs.nameKey)

        // 256x144, red = source column. The pipeline's colour handling bends the tone curve, so first
        // render at zoom 1 (16:9 crop = whole picture) to measure the curve f(source column) -> value.
        let src = gradientBuffer(width: 256, height: 144)
        d.set(FramingAspect.r16x9.rawValue, forKey: OutputFramingPrefs.aspectKey)
        d.set(1.0, forKey: OutputFramingPrefs.zoomKey)
        let base = try XCTUnwrap(OutputProcessor().process(src))
        let curve = (0..<256).map { Double(red(base, x: $0, y: 72)) }
        XCTAssertGreaterThan(curve[255] - curve[0], 100, "baseline must preserve the gradient")

        // Zoom 2, pan 0 shows source columns 64..<192 stretched across 256 output columns.
        d.set(2.0, forKey: OutputFramingPrefs.zoomKey)
        let out = try XCTUnwrap(OutputProcessor().process(src))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 256)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 144)
        func expect(_ col: Int, _ srcCol: Double, _ line: UInt = #line) {
            let lo = Int(srcCol.rounded(.down)), hi = min(255, lo + 1), t = srcCol - Double(lo)
            let want = curve[lo] * (1 - t) + curve[hi] * t
            XCTAssertEqual(Double(red(out, x: col, y: 72)), want, accuracy: 3, "output column \(col) should show source column \(srcCol)", line: line)
        }
        expect(128, 128)   // centre pixel is the source centre
        expect(2, 65)      // left edge shows source column ~64, not 0 or 128
        expect(253, 190.5) // right edge shows source column ~191
        expect(64, 96)
        expect(192, 160)
    }

    // MARK: LUT limits and caching

    func testParserRejectsNonFiniteAndOversizedInput() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\nnan 0 0\n" + String(repeating: "0 0 0\n", count: 7)))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\ninf 0 0\n" + String(repeating: "0 0 0\n", count: 7)))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\nDOMAIN_MAX nan 1 1\n"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 130\n"))
        // More values than declared throws as soon as the count is exceeded, with the precise error.
        let extra = "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 9)
        XCTAssertThrowsError(try CubeLUT.parse(extra)) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .wrongCount(expected: 8, got: 9))
        }
        XCTAssertEqual(CubeLUT.maxValues, 129 * 129 * 129 * 3)
    }

    func testOversizedFileIsRejectedBeforeReading() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).cube")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: f) }
        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: UInt64(CubeLUT.maxFileBytes) + 1) // sparse
        try h.close()
        XCTAssertThrowsError(try LUTLibrary.readText(f)) { XCTAssertEqual($0 as? CubeLUT.ParseError, .tooLarge) }
        XCTAssertThrowsError(try LUTLibrary.importFile(f))
    }

    func testIdentityCubeIsBuiltOnceAndIntensityFades() throws {
        XCTAssertEqual(CubeLUT.identityCube(size: 5).count, 5 * 5 * 5 * 4)
        let lut = try CubeLUT.parse(identityCube(size: 3))
        func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        let faded = floats(lut.cubeData(intensity: 0.25))
        for (a, b) in zip(faded, lut.rgba) { XCTAssertEqual(a, b, accuracy: 1e-6) } // identity look stays identity
    }

    func testFilterAndParseFailureAreCached() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luts-\(UUID().uuidString)")
        let savedDir = LUTLibrary.directory
        let d = UserDefaults.standard
        let keys = [LookPrefs.nameKey, LookPrefs.intensityKey]
        let saved = keys.map { d.object(forKey: $0) }
        LUTLibrary.directory = dir
        defer {
            LUTLibrary.directory = savedDir; try? FileManager.default.removeItem(at: dir)
            for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try identityCube(size: 4).write(to: dir.appendingPathComponent("Good.cube"), atomically: true, encoding: .utf8)
        try "garbage".write(to: dir.appendingPathComponent("Bad.cube"), atomically: true, encoding: .utf8)

        d.set("Good", forKey: LookPrefs.nameKey); d.set(0.5, forKey: LookPrefs.intensityKey)
        let before = LUTLibrary.parseCount
        let f1 = try XCTUnwrap(LUTLibrary.currentFilter())
        let f2 = try XCTUnwrap(LUTLibrary.currentFilter())
        XCTAssertEqual(LUTLibrary.parseCount - before, 1, "file parsed once")
        XCTAssertFalse(f1 === f2, "each caller gets its own filter instance")
        XCTAssertEqual(f1.value(forKey: "inputCubeDimension") as? Int, 4)
        XCTAssertEqual(f1.value(forKey: "inputCubeData") as? Data, f2.value(forKey: "inputCubeData") as? Data)
        d.set(1.0, forKey: LookPrefs.intensityKey)
        let f3 = try XCTUnwrap(LUTLibrary.currentFilter())
        XCTAssertNotNil(f3.value(forKey: "inputCubeData"))

        d.set("Bad", forKey: LookPrefs.nameKey)
        let beforeBad = LUTLibrary.parseCount
        for _ in 0..<5 { XCTAssertNil(LUTLibrary.currentFilter()) }
        XCTAssertEqual(LUTLibrary.parseCount - beforeBad, 1, "invalid file is read once, not per frame")
    }
}
