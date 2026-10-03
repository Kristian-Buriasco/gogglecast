import Testing
import Foundation
@testable import GogglesView

@Suite("MPEGTSMuxer")
struct MPEGTSMuxerTests {
    static let sps = Data([0x67, 0x64, 0x00, 0x28])
    static let pps = Data([0x68, 0xEE, 0x3C, 0x80])

    static func avcc(_ nals: [[UInt8]]) -> Data {
        var d = Data()
        for n in nals { d.append(contentsOf: [0, 0, UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n) }
        return d
    }

    static func packets(_ d: Data) -> [[UInt8]] {
        stride(from: 0, to: d.count, by: 188).map { [UInt8](d[d.startIndex + $0..<d.startIndex + $0 + 188]) }
    }

    static func pid(_ p: [UInt8]) -> UInt16 { UInt16(p[1] & 0x1F) << 8 | UInt16(p[2]) }

    func sampleStream() -> Data {
        var m = MPEGTSMuxer()
        var out = Data()
        for i in 0..<40 {
            let key = i % 20 == 0
            let payload = [UInt8](repeating: UInt8(i & 0x7F | 1), count: key ? 2000 : 30 + i * 7)
            out.append(m.mux(avcc: Self.avcc([[key ? 0x65 : 0x41] + payload]), isKeyframe: key,
                             parameterSets: [Self.sps, Self.pps], presentationTime: 1000 + Double(i) / 30))
        }
        return out
    }

    @Test("188-byte alignment, sync bytes, per-PID continuity")
    func structure() {
        let pkts = Self.packets(sampleStream())
        #expect(!pkts.isEmpty)
        var last: [UInt16: UInt8] = [:]
        for p in pkts {
            #expect(p.count == 188 && p[0] == 0x47)
            let pid = Self.pid(p), cc = p[3] & 0x0F
            if let l = last[pid] { #expect(cc == (l + 1) & 0x0F) }
            last[pid] = cc
        }
        #expect(Set(last.keys) == [0, MPEGTSMuxer.pmtPID, MPEGTSMuxer.videoPID])
    }

    @Test("PAT/PMT CRC32 validates (CRC over whole section is zero)")
    func crc() {
        for s in [MPEGTSMuxer.patSection(), MPEGTSMuxer.pmtSection()] {
            #expect(MPEGTSMuxer.crc32mpeg(s) == 0)
        }
        // Known MPEG-2 CRC check value
        #expect(MPEGTSMuxer.crc32mpeg(Array("123456789".utf8)) == 0x0376E6E7)
    }

    @Test("PSI precedes the first keyframe and PES carries PTS=DTS, PCR and RAI")
    func firstFrame() {
        var m = MPEGTSMuxer()
        let out = m.mux(avcc: Self.avcc([[0x65, 1, 2, 3]]), isKeyframe: true,
                        parameterSets: [Self.sps, Self.pps], presentationTime: 5.0)
        let pkts = Self.packets(out)
        #expect(Self.pid(pkts[0]) == 0 && Self.pid(pkts[1]) == MPEGTSMuxer.pmtPID)
        let v = pkts[2]
        #expect(Self.pid(v) == MPEGTSMuxer.videoPID && v[1] & 0x40 != 0)
        #expect(v[3] & 0x30 == 0x30)
        #expect(v[5] == 0x50) // PCR + random access
        let s = 5 + Int(v[4]) // stuffing may follow the PCR
        #expect(Array(v[s..<s + 3]) == [0x00, 0x00, 0x01])
    }

    @Test("PES PTS encoding round-trips")
    func ptsRoundTrip() {
        for v: UInt64 in [0, 1, 9000, 90_000 * 3600, 0x1_FFFF_FFFF] {
            let b = MPEGTSMuxer.timestamp(prefix: 0b0010, v)
            let dec = UInt64(b[0] >> 1 & 7) << 30 | UInt64(b[1]) << 22 | UInt64(b[2] >> 1) << 15
                | UInt64(b[3]) << 7 | UInt64(b[4] >> 1)
            #expect(dec == v)
            #expect(b[0] & 1 == 1 && b[2] & 1 == 1 && b[4] & 1 == 1)
        }
    }

    @Test("PES payload decodes to rebased PTS and Annex-B payload")
    func pesContent() {
        var m = MPEGTSMuxer()
        _ = m.mux(avcc: Self.avcc([[0x65, 9]]), isKeyframe: true, parameterSets: [], presentationTime: 10)
        let out = m.mux(avcc: Self.avcc([[0x41, 7]]), isKeyframe: false, parameterSets: [], presentationTime: 10.5)
        let p = Self.packets(out).last { Self.pid($0) == MPEGTSMuxer.videoPID }!
        // Non-key: adaptation has PCR; payload follows AF.
        let afLen = Int(p[4]); let pes = Array(p[(5 + afLen)...])
        #expect(Array(pes[0..<4]) == [0, 0, 1, 0xE0])
        let t = Array(pes[9..<14])
        let pts = UInt64(t[0] >> 1 & 7) << 30 | UInt64(t[1]) << 22 | UInt64(t[2] >> 1) << 15 | UInt64(t[3]) << 7 | UInt64(t[4] >> 1)
        #expect(pts == 45_000 + MPEGTSMuxer.ptsLead)
        #expect(Array(pes[19...]) == [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x41, 7])
    }

    @Test("Annex-B conversion: AUD, SPS/PPS only on keyframes, 4-byte start codes")
    func annexB() {
        let avcc = Self.avcc([[0x65, 1], [0x65, 2, 3]])
        let key = [UInt8](MPEGTSMuxer.annexB(avcc: avcc, isKeyframe: true, parameterSets: [Self.sps, Self.pps]))
        let sc: [UInt8] = [0, 0, 0, 1]
        #expect(key == sc + [0x09, 0xF0] + sc + [UInt8](Self.sps) + sc + [UInt8](Self.pps) + sc + [0x65, 1] + sc + [0x65, 2, 3])
        let non = [UInt8](MPEGTSMuxer.annexB(avcc: avcc, isKeyframe: false, parameterSets: [Self.sps]))
        #expect(non == sc + [0x09, 0xF0] + sc + [0x65, 1] + sc + [0x65, 2, 3])
    }

    @Test("PSI repeats at least every 100 ms")
    func psiRepeat() {
        var m = MPEGTSMuxer()
        var psiTimes = 0
        for i in 0..<30 {
            let out = m.mux(avcc: Self.avcc([[i == 0 ? 0x65 : 0x41, 1]]), isKeyframe: i == 0,
                            parameterSets: [], presentationTime: Double(i) / 30)
            if Self.packets(out).contains(where: { Self.pid($0) == 0 }) { psiTimes += 1 }
        }
        #expect(psiTimes >= 9)
    }

    @Test("Write TS file for external ffprobe validation")
    func writeFile() throws {
        guard let path = ProcessInfo.processInfo.environment["TS_OUT"],
              let src = ProcessInfo.processInfo.environment["H264_IN"],
              let raw = FileManager.default.contents(atPath: src) else { return }
        let b = [UInt8](raw)
        // Split Annex-B into NALs, group into access units by AUD/first_mb... use slices heuristically.
        var starts: [Int] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var m = MPEGTSMuxer()
        var out = Data()
        var sps = Data(), pps = Data()
        var au: [[UInt8]] = [], key = false, n = 0
        func flush() {
            guard !au.isEmpty else { return }
            out.append(m.mux(avcc: Self.avccBig(au), isKeyframe: key, parameterSets: [sps, pps], presentationTime: Double(n) / 30))
            n += 1; au = []; key = false
        }
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
            while e > s, b[e - 1] == 0 { e -= 1 }
            let nal = Array(b[s..<e]); let t = nal[0] & 0x1F
            if t == 7 { sps = Data(nal) } else if t == 8 { pps = Data(nal) }
            else if t == 1 || t == 5 {
                if nal.count > 1, nal[1] & 0x80 != 0 { flush() } // first_mb_in_slice == 0
                au.append(nal); if t == 5 { key = true }
            }
        }
        flush()
        try out.write(to: URL(fileURLWithPath: path))
    }

    static func avccBig(_ nals: [[UInt8]]) -> Data {
        var d = Data()
        for n in nals {
            let c = n.count
            d.append(contentsOf: [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)] + n)
        }
        return d
    }
}
