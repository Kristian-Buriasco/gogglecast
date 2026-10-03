import Testing
import Foundation
import CoreMedia
@testable import GogglesView

/// Real libsrt + ffmpeg loopback. Opt-in: GV_SRT_LOOPBACK=1 (needs `brew install srt ffmpeg` with libsrt).
@Suite("SRT loopback", .enabled(if: ProcessInfo.processInfo.environment["GV_SRT_LOOPBACK"] == "1"))
struct SRTLoopbackTests {
    static func run(_ args: [String], wait: Bool = true) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        if wait { p.waitUntilExit() }
        return p
    }

    static func nals(_ d: [UInt8]) -> [[UInt8]] {
        var starts: [(Int, Int)] = [] // (index of start code, payload start)
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 { starts.append((i, i + 3)); i += 3 }
            else { i += 1 }
        }
        return starts.enumerated().map { k, s in
            var end = k + 1 < starts.count ? starts[k + 1].0 : d.count
            while end > s.1, d[end - 1] == 0 { end -= 1 }
            return Array(d[s.1..<end])
        }
    }

    @Test("ffmpeg caller receives decodable MPEG-TS from SRT listener")
    func loopback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("srtloop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let h264 = dir.appendingPathComponent("in.h264").path, out = dir.appendingPathComponent("out.ts").path
        _ = try Self.run(["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30", "-t", "4",
                          "-c:v", "libx264", "-bf", "0", "-g", "30", "-x264-params", "aud=0:slices=1", "-f", "h264", h264])
        let units = Self.nals([UInt8](try Data(contentsOf: URL(fileURLWithPath: h264))))
        let sps = units.first { $0[0] & 0x1F == 7 }!, pps = units.first { $0[0] & 0x1F == 8 }!
        var fd: CMFormatDescription?
        try sps.withUnsafeBufferPointer { s in try pps.withUnsafeBufferPointer { p in
            let ptrs = [s.baseAddress!, p.baseAddress!]
            #expect(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                parameterSetPointers: ptrs, parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                formatDescriptionOut: &fd) == noErr)
        } }

        let port = 19000 + Int.random(in: 0..<500)
        let out_ = SRTOutput()
        out_.start(mode: .listener, host: "", port: port, latencyMs: 120, passphrase: "")
        #expect(out_.isStreaming)
        Thread.sleep(forTimeInterval: 0.5)
        let rx = try Self.run(["ffmpeg", "-y", "-i", "srt://127.0.0.1:\(port)?mode=caller", "-c", "copy", "-t", "3", "-f", "mpegts", out],
                              wait: false)
        Thread.sleep(forTimeInterval: 1.5)

        var pts = 0
        for u in units where [1, 5].contains(u[0] & 0x1F) {
            var avcc = Data([0, 0, UInt8(u.count >> 8), UInt8(u.count & 0xFF)] + u)
            if u.count > 65535 { avcc = Data([UInt8(u.count >> 24), UInt8(u.count >> 16 & 255), UInt8(u.count >> 8 & 255), UInt8(u.count & 255)] + u) }
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &bb)
            avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: avcc.count) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 30), decodeTimeStamp: .invalid)
            var size = avcc.count
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
            if u[0] & 0x1F != 5, let sb,
               let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
                CFDictionarySetValue(unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self),
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            out_.enqueue(sb!)
            pts += 1
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        for _ in 0..<60 where rx.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        if rx.isRunning { rx.terminate() }
        rx.waitUntilExit()
        out_.stop()
        #expect(out_.bytesSent > 0)
        let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
        #expect((size ?? 0) > 10_000)
        let probe = try Self.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", out])
        #expect(probe.terminationStatus == 0)
    }
}
