import AppKit
import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import GogglesView
import GogglesH264

struct BurnInLayoutTests {
    let frame = CGSize(width: 1920, height: 1080)

    @Test func marginIsThreePercentOfHeight() {
        #expect(BurnInLayout.margin(for: frame) == 32)
    }

    @Test func logoRectInEachCorner() {
        let logo = CGSize(width: 400, height: 200)
        let m: CGFloat = 32
        let tl = BurnInLayout.logoRect(frame: frame, logo: logo, corner: .topLeft, scalePercent: 20, margin: m)
        #expect(tl == CGRect(x: 32, y: 1080 - 32 - 192, width: 384, height: 192))
        let tr = BurnInLayout.logoRect(frame: frame, logo: logo, corner: .topRight, scalePercent: 20, margin: m)
        #expect(tr == CGRect(x: 1920 - 32 - 384, y: 856, width: 384, height: 192))
        let bl = BurnInLayout.logoRect(frame: frame, logo: logo, corner: .bottomLeft, scalePercent: 20, margin: m)
        #expect(bl == CGRect(x: 32, y: 32, width: 384, height: 192))
        let br = BurnInLayout.logoRect(frame: frame, logo: logo, corner: .bottomRight, scalePercent: 20, margin: m)
        #expect(br == CGRect(x: 1504, y: 32, width: 384, height: 192))
    }

    @Test func tallLogoShrinksToFitHeight() {
        let r = BurnInLayout.logoRect(frame: frame, logo: CGSize(width: 100, height: 1000),
                                      corner: .bottomLeft, scalePercent: 100, margin: 32)
        #expect(r.height == CGFloat(1016))
        #expect(r.width == 102)  // 1016 / 10, rounded
        #expect(r.minY == 32)
    }

    @Test func scaleIsClampedAndDegenerateLogoIsEmpty() {
        let small = BurnInLayout.logoRect(frame: frame, logo: CGSize(width: 100, height: 100),
                                          corner: .topLeft, scalePercent: 0, margin: 0)
        #expect(small.width == 96)  // clamped to 5%
        let huge = BurnInLayout.logoRect(frame: frame, logo: CGSize(width: 100, height: 10),
                                         corner: .topLeft, scalePercent: 500, margin: 32)
        #expect(huge.width == CGFloat(1856))
        #expect(BurnInLayout.logoRect(frame: frame, logo: .zero, corner: .topLeft, scalePercent: 20, margin: 32) == .zero)
    }

    @Test func textCornerMirrorsLogo() {
        #expect(BurnInCorner.topRight.mirroredHorizontally == .topLeft)
        #expect(BurnInCorner.bottomLeft.mirroredHorizontally == .bottomRight)
    }

    @Test func textLines() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = BurnInInfo(fps: 60, bitrateKbps: 25_340, resolution: "1920x1080")
        #expect(BurnInLayout.textLines(info: info, date: date, showTime: true, showStats: true, timeZone: utc)
                == ["2023-11-14 22:13:20", "1920x1080 · 60 fps · 25.3 Mbps"])
        #expect(BurnInLayout.textLines(info: info, date: date, showTime: false, showStats: false).isEmpty)
        #expect(BurnInLayout.textLines(info: BurnInInfo(fps: 30), date: date, showTime: false, showStats: true) == ["30 fps"])
        #expect(BurnInLayout.textLines(info: BurnInInfo(), date: date, showTime: false, showStats: true).isEmpty)
    }

    @Test func fileName() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(BurnInLayout.fileName(for: date, prefix: "GogglesView", ext: "mp4", timeZone: utc)
                == "GogglesView-burned-2023-11-14-22-13-20.mp4")
    }

    @Test func prefClamping() {
        let d = UserDefaults(suiteName: "BurnInTests-\(UUID().uuidString)")!
        #expect(BurnInPrefs.int("k", default: 12, range: BurnInPrefs.bitrateRange, defaults: d) == 12)
        d.set(0, forKey: "k")
        #expect(BurnInPrefs.int("k", default: 12, range: BurnInPrefs.bitrateRange, defaults: d) == 2)
        d.set(1000, forKey: "k")
        #expect(BurnInPrefs.int("k", default: 12, range: BurnInPrefs.bitrateRange, defaults: d) == 100)
        #expect(BurnInPrefs.clamp(-5, to: BurnInPrefs.opacityRange) == 0)
        #expect(BurnInPrefs.clamp(150, to: BurnInPrefs.scaleRange) == 100)
    }

    @Test func keyframeDetectionFromNALType() throws {
        let fmt = try ParameterSetSplitter.formatDescription(fromBundledBlob: BurnInFixture.spsPPS)
        func sample(_ nals: [[UInt8]]) throws -> CMSampleBuffer {
            var avcc = Data()
            for n in nals {
                var len = UInt32(n.count).bigEndian
                withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: n)
            }
            return try DecodeSession.makeSampleBuffer(avccData: avcc, formatDescription: fmt, hostTime: 1)
        }
        #expect(BurnInRecorder.isKeyframe(try sample([[0x06, 0x05, 0x01], [0x65, 0x88, 0x80]])))
        #expect(!BurnInRecorder.isKeyframe(try sample([[0x41, 0x9a, 0x00]])))
    }
}

enum BurnInFixture {
    /// SPS + PPS from an ffmpeg/x264 1920x1080 encode (Annex-B).
    static let spsPPS: [UInt8] = [
        0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x28, 0xda, 0x01, 0xe0, 0x08, 0x9f, 0x97, 0x01, 0x10, 0x00, 0x00, 0x03,
        0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x2a,
        0, 0, 0, 1, 0x68, 0xce, 0x0f, 0xc8,
    ]
}


/// End-to-end: ffmpeg-generated Annex-B H.264 -> DecodeSession sample buffers
/// -> BurnInRecorder -> ffprobe + pixel check of the burned-in logo.
struct BurnInIntegrationTests {
    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileReadUnknown) }
        return data
    }

    @Test(.enabled(if: tool("ffmpeg") != nil && tool("ffprobe") != nil), arguments: [BurnInCodec.h264, .hevc])
    func burnsLogoIntoReencodedFile(codec: BurnInCodec) async throws {
        let ffmpeg = Self.tool("ffmpeg")!, ffprobe = Self.tool("ffprobe")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2 s of solid blue 1080p30, IDR every 30 frames, raw Annex-B.
        let h264 = dir.appendingPathComponent("in.h264")
        try Self.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=blue:s=1920x1080:r=30", "-frames:v", "60",
                              "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                              "-g", "30", "-bf", "0", "-f", "h264", h264.path])

        // Solid red 400x200 logo.
        let logoRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: logoRep)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 200).fill()
        NSGraphicsContext.restoreGraphicsState()
        let logoURL = dir.appendingPathComponent("logo.png")
        try logoRep.representation(using: .png, properties: [:])!.write(to: logoURL)

        let nals = ParameterSetSplitter.split([UInt8](try Data(contentsOf: h264)))
        let sps = try #require(nals.first { $0.type == 7 }), pps = try #require(nals.first { $0.type == 8 })
        let fmt = try ParameterSetSplitter.makeFormatDescription(sps: sps.payload, pps: pps.payload)
        let slices = nals.filter { $0.type == 1 || $0.type == 5 }
        #expect(slices.count == 60)

        let recorder = BurnInRecorder()
        let out = dir.appendingPathComponent("out-burned.mov")
        var settings = BurnInSettings()
        settings.logo = CIImage(contentsOf: logoURL)
        settings.corner = .topRight
        settings.scalePercent = 20
        settings.opacityPercent = 100
        settings.showTime = true
        settings.showStats = true
        settings.bitrateMbps = 12
        settings.codec = codec
        try recorder.start(to: out, settings: settings,
                           info: { BurnInInfo(fps: 30, bitrateKbps: 8000, resolution: "1920x1080") })

        let base: UInt64 = 5_000_000_000_000  // uptime nanoseconds, like the helper's stamps
        for (i, nal) in slices.enumerated() {
            var avcc = Data()
            var len = UInt32(nal.payload.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal.payload)
            let sb = try DecodeSession.makeSampleBuffer(avccData: avcc, formatDescription: fmt,
                                                        hostTime: base + UInt64(i) * 33_333_333)
            recorder.enqueue(sb)
            try await Task.sleep(nanoseconds: 33_000_000)  // real-time pacing
        }
        let written: URL? = await withCheckedContinuation { c in recorder.stop { c.resume(returning: $0) } }
        #expect(written == out)

        let probe = String(decoding: try Self.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-count_frames",
            "-show_entries", "stream=codec_name,width,height,nb_read_frames:format=duration",
            "-of", "default=noprint_wrappers=1", out.path]), as: UTF8.self)
        print("burn-in ffprobe:\n\(probe)")
        #expect(probe.contains("codec_name=\(codec == .h264 ? "h264" : "hevc")"))
        #expect(probe.contains("width=1920"))
        #expect(probe.contains("height=1080"))
        let fields = Dictionary(uniqueKeysWithValues: probe.split(separator: "\n").compactMap { line -> (String, String)? in
            let kv = line.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        })
        let duration = Double(fields["duration"] ?? "") ?? 0
        let frames = Int(fields["nb_read_frames"] ?? "") ?? 0
        #expect(abs(duration - 2.0) < 0.2)
        #expect(frames >= 40) // real-time paced; frames drop by design under CPU load

        // Frame 30 as raw RGB: logo region red, background blue.
        let raw = try Self.run(ffmpeg, ["-v", "error", "-i", out.path, "-vf", "select=eq(n\\,30)",
                                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
        #expect(raw.count == 1920 * 1080 * 3)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = (y * 1920 + x) * 3
            return (Int(raw[o]), Int(raw[o + 1]), Int(raw[o + 2]))
        }
        // Logo rect (top-left origin): x 1504..<1888, y 32..<224.
        let inLogo = px(1696, 128), background = px(960, 700), outsideLogo = px(1450, 128)
        print("burn-in pixels: logo=\(inLogo) background=\(background) leftOfLogo=\(outsideLogo)")
        #expect(inLogo.0 > 200 && inLogo.1 < 60 && inLogo.2 < 60)
        #expect(background.2 > 200 && background.0 < 60)
        #expect(outsideLogo.2 > 200 && outsideLogo.0 < 60)
        // Stats text box (top-left, mirrored from the logo) darkens the blue there.
        let textBox = px(40, 40)
        #expect(textBox.2 < 200)
    }
}
