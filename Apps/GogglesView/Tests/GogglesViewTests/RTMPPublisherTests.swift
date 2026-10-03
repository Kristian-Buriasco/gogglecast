import Testing
import Foundation
@testable import GogglesView

@Suite("RTMP")
struct RTMPPublisherTests {
    @Test func amf0Encoding() {
        #expect(AMF0.encode(.number(1)) == [0, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0])
        #expect(AMF0.encode(.string("hi")) == [2, 0, 2, 0x68, 0x69])
        #expect(AMF0.encode(.bool(true)) == [1, 1])
        #expect(AMF0.encode(.null) == [5])
        #expect(AMF0.encode(.object([AMF0.Pair("a", .null)])) == [3, 0, 1, 0x61, 5, 0, 0, 9])
        #expect(AMF0.encode(.ecmaArray([AMF0.Pair("a", .null)])) == [8, 0, 0, 0, 1, 0, 1, 0x61, 5, 0, 0, 9])
    }

    @Test func amf0RoundTrip() {
        let vals: [AMF0.Value] = [.string("onStatus"), .number(0), .null,
                                  .object([AMF0.Pair("code", .string("NetStream.Publish.Start")), AMF0.Pair("n", .number(2.5)),
                                           AMF0.Pair("b", .bool(false))])]
        #expect(AMF0.decode(AMF0.encode(vals)) == vals)
        #expect(AMF0.decode([2, 0, 9, 0x61]).isEmpty) // truncated string
    }

    @Test func chunkingSplitsAndReassembles() {
        let payload = (0..<10_000).map { UInt8($0 & 0xFF) }
        let wire = RTMPChunk.encode(csid: 6, typeID: 9, streamID: 1, timestamp: 1234, payload: payload, chunkSize: 4096)
        // 12-byte header + payload + 2 continuation basic headers
        #expect(wire.count == 12 + payload.count + 2)
        #expect(wire[0] == 6)
        #expect(Array(wire[4...6]) == [0, 0x27, 0x10])
        #expect(wire[12 + 4096] == 0xC6)
        var r = RTMPChunk.Reader()
        // The reader starts at the default chunk size, so announce 4096 first.
        let setSize = RTMPChunk.encode(csid: 2, typeID: 1, streamID: 0, timestamp: 0, payload: RTMPChunk.be32(4096), chunkSize: 128)
        #expect(r.feed(setSize).count == 1)
        var got: [RTMPChunk.Message] = []
        for b in wire { got += r.feed([b]) } // byte-at-a-time
        #expect(got == [RTMPChunk.Message(typeID: 9, streamID: 1, timestamp: 1234, payload: payload)])
    }

    @Test func extendedTimestamp() {
        let wire = RTMPChunk.encode(csid: 4, typeID: 9, streamID: 1, timestamp: 0x0200_0000, payload: [UInt8](repeating: 7, count: 300), chunkSize: 128)
        #expect(Array(wire[1...3]) == [0xFF, 0xFF, 0xFF])
        #expect(Array(wire[12...15]) == [2, 0, 0, 0])
        var r = RTMPChunk.Reader()
        let m = r.feed(wire)
        #expect(m.count == 1 && m[0].timestamp == 0x0200_0000 && m[0].payload.count == 300)
    }

    @Test func avcConfigRecord() {
        let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAA]), pps = Data([0x68, 0xEE])
        let r = RTMPFLV.avcDecoderConfigurationRecord(sps: [sps], pps: [pps])
        #expect(r == [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0, 5, 0x67, 0x64, 0x00, 0x28, 0xAA, 1, 0, 2, 0x68, 0xEE])
        #expect(RTMPFLV.avcDecoderConfigurationRecord(sps: [], pps: [pps]) == nil)
    }

    @Test func videoTagHeader() {
        #expect(RTMPFLV.videoTag(keyframe: true, sequenceHeader: true, data: [9]) == [0x17, 0, 0, 0, 0, 9])
        #expect(RTMPFLV.videoTag(keyframe: false, sequenceHeader: false, data: []) == [0x27, 1, 0, 0, 0])
        #expect(RTMPFLV.videoTag(keyframe: true, sequenceHeader: false, compositionTime: 0x010203, data: []) == [0x17, 1, 1, 2, 3])
    }

    @Test func urlParsingAndRedaction() {
        #expect(RTMPTarget.parse("rtmp://live.twitch.tv/app") == RTMPTarget(secure: false, host: "live.twitch.tv", port: 1935, app: "app"))
        #expect(RTMPTarget.parse("rtmps://a.rtmps.youtube.com:443/live2")?.tcURL == "rtmps://a.rtmps.youtube.com/live2")
        #expect(RTMPTarget.parse("rtmp://h:19350/live")?.tcURL == "rtmp://h:19350/live")
        #expect(RTMPTarget.parse("http://x/y") == nil)
        #expect(RTMPTarget.parse("rtmp://x") == nil)
        #expect(redactStreamKey("bad key live_123 in", key: "live_123") == "bad key *** in")
    }

    @Test func metadataContainsRequiredFields() {
        let v = AMF0.decode(RTMPFLV.onMetaData(width: 1920, height: 1080, fps: 60))
        #expect(v[0].string == "@setDataFrame" && v[1].string == "onMetaData")
        let p = v[2].properties ?? []
        #expect(p.first { $0.key == "videocodecid" }?.value.number == 7)
        #expect(p.first { $0.key == "width" }?.value.number == 1920)
    }

    /// Needs GV_H264_FILE (Annex-B, x264 with aud=1) and a receiver, e.g.
    /// ffmpeg -listen 1 -i rtmp://127.0.0.1:19350/live/test -c copy /tmp/out.flv
    @Test func liveAgainstReceiver() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["GV_H264_FILE"], let url = env["GV_RTMP_URL"] else { return }
        let frames = try TestH264.accessUnits(path: file)
        let pub = RTMPPublisher()
        pub.start(url: url, streamKey: "test")
        for _ in 0..<100 where !pub.isLive { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(pub.isLive, "never went live: \(pub.lastError ?? pub.status)")
        for (i, f) in frames.enumerated() {
            pub.submit(avcc: f.avcc, isKeyframe: f.isKey, parameterSets: f.isKey ? f.parameterSets : [],
                       width: 1920, height: 1080, fps: 30, pts: Double(i) / 30)
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        pub.stop()
    }
}

enum TestH264 {
    struct AU { var avcc = Data(); var isKey = false; var parameterSets: [Data] = [] }

    /// Splits an Annex-B stream into access units at AUDs and converts to AVCC.
    static func accessUnits(path: String) throws -> [AU] {
        let b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var starts: [Int] = [] // payload start of each NAL
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var out: [AU] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
            while e > s, b[e - 1] == 0 { e -= 1 }
            let nal = Array(b[s..<e])
            guard let h = nal.first else { continue }
            switch h & 0x1F {
            case 9: out.append(AU())
            case 7, 8: out[out.count - 1].parameterSets.append(Data(nal))
            default:
                if h & 0x1F == 5 { out[out.count - 1].isKey = true }
                let n = nal.count
                out[out.count - 1].avcc.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal)
            }
        }
        return out
    }
}
