import Foundation

/// Pure single-program, single-stream (H.264) MPEG-TS muxer. No I/O, no
/// CoreMedia: callers hand in AVCC bytes + parameter sets and get back a
/// whole number of 188-byte packets.
struct MPEGTSMuxer {
    static let packetSize = 188
    static let pmtPID: UInt16 = 0x100
    static let videoPID: UInt16 = 0x101
    static let psiInterval: Double = 0.1
    /// PTS leads PCR by this much so the decoder has buffering headroom.
    static let ptsLead: UInt64 = 9000 // 100 ms @ 90 kHz

    private var continuity: [UInt16: UInt8] = [:]
    private var baseTime: Double?
    private var lastPSITime: Double = -.infinity

    init() {}

    /// - Parameters:
    ///   - avcc: 4-byte-length-prefixed NAL units for one access unit.
    ///   - parameterSets: SPS/PPS NALs without start codes; emitted on keyframes only.
    ///   - presentationTime: seconds on any monotonic clock; rebased to the first sample.
    mutating func mux(avcc: Data, isKeyframe: Bool, parameterSets: [Data], presentationTime: Double) -> Data {
        let base = baseTime ?? presentationTime
        baseTime = base
        let rebased = max(0, presentationTime - base)
        let pcr90k = UInt64(rebased * 90_000)
        let pts = pcr90k + Self.ptsLead

        var out = Data()
        if isKeyframe || rebased - lastPSITime >= Self.psiInterval {
            out.append(psiPacket(pid: 0, section: Self.patSection()))
            out.append(psiPacket(pid: Self.pmtPID, section: Self.pmtSection()))
            lastPSITime = rebased
        }
        let es = Self.annexB(avcc: avcc, isKeyframe: isKeyframe, parameterSets: parameterSets)
        out.append(pesPackets(es: es, pts: pts, pcr90k: pcr90k, keyframe: isKeyframe))
        return out
    }

    // MARK: - Annex-B

    static func annexB(avcc: Data, isKeyframe: Bool, parameterSets: [Data]) -> Data {
        let sc: [UInt8] = [0, 0, 0, 1]
        var out = Data(sc + [0x09, 0xF0]) // AUD, primary_pic_type = any
        if isKeyframe {
            for ps in parameterSets { out.append(contentsOf: sc); out.append(ps) }
        }
        let bytes = [UInt8](avcc)
        var i = 0
        while i + 4 <= bytes.count {
            let len = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard len > 0, i + len <= bytes.count else { break }
            out.append(contentsOf: sc)
            out.append(contentsOf: bytes[i..<i + len])
            i += len
        }
        return out
    }

    // MARK: - PSI

    static func patSection() -> [UInt8] {
        let body: [UInt8] = [
            0x00, 0x01,             // transport_stream_id
            0xC1, 0x00, 0x00,       // version 0, current, section 0/0
            0x00, 0x01,             // program 1
            0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF)
        ]
        return section(tableID: 0x00, body: body)
    }

    static func pmtSection() -> [UInt8] {
        let body: [UInt8] = [
            0x00, 0x01,
            0xC1, 0x00, 0x00,
            0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), // PCR PID
            0xF0, 0x00,                                           // no program info
            0x1B, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00
        ]
        return section(tableID: 0x02, body: body)
    }

    private static func section(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        let length = body.count + 4 // + CRC
        var s: [UInt8] = [tableID, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF)] + body
        let crc = crc32mpeg(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    static func crc32mpeg(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }

    private mutating func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var p = [UInt8](repeating: 0xFF, count: Self.packetSize)
        writeHeader(&p, pid: pid, pusi: true, adaptation: false)
        p[4] = 0x00 // pointer_field
        for (i, b) in section.enumerated() { p[5 + i] = b }
        return Data(p)
    }

    // MARK: - PES

    private mutating func pesPackets(es: Data, pts: UInt64, pcr90k: UInt64, keyframe: Bool) -> Data {
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, // unbounded length (video)
                            0x80, 0xC0, 10]                      // PTS+DTS present
        pes += Self.timestamp(prefix: 0b0011, pts)
        pes += Self.timestamp(prefix: 0b0001, pts)
        pes += es

        var out = Data(capacity: (pes.count / 184 + 2) * Self.packetSize)
        var offset = 0
        var first = true
        while offset < pes.count {
            let remaining = pes.count - offset
            let minAF = first ? 8 : 0 // length + flags + 6-byte PCR
            let chunk = min(remaining, 184 - minAF)
            let afTotal = 184 - chunk // adaptation bytes incl. length byte; stuffing lives here

            var p = [UInt8](repeating: 0xFF, count: Self.packetSize)
            writeHeader(&p, pid: Self.videoPID, pusi: first, adaptation: afTotal > 0)
            var pos = 4
            if afTotal > 0 {
                p[pos] = UInt8(afTotal - 1)
                if afTotal >= 2 {
                    p[pos + 1] = first ? (keyframe ? 0x50 : 0x10) : 0x00 // PCR flag, RAI on keyframes
                    if first {
                        let b = pcr90k
                        p[pos + 2] = UInt8(b >> 25 & 0xFF)
                        p[pos + 3] = UInt8(b >> 17 & 0xFF)
                        p[pos + 4] = UInt8(b >> 9 & 0xFF)
                        p[pos + 5] = UInt8(b >> 1 & 0xFF)
                        p[pos + 6] = UInt8((b & 1) << 7) | 0x7E // reserved bits, ext[8] = 0
                        p[pos + 7] = 0x00
                    }
                } // remaining AF bytes stay 0xFF (stuffing)
                pos += afTotal
            }
            p.replaceSubrange(pos..<pos + chunk, with: pes[offset..<offset + chunk])
            offset += chunk
            first = false
            out.append(contentsOf: p)
        }
        return out
    }

    /// 33-bit PTS/DTS in the 5-byte PES encoding with marker bits.
    static func timestamp(prefix: UInt8, _ v: UInt64) -> [UInt8] {
        let v = v & 0x1_FFFF_FFFF
        return [prefix << 4 | UInt8(v >> 30 & 0x7) << 1 | 1,
                UInt8(v >> 22 & 0xFF),
                UInt8(v >> 15 & 0x7F) << 1 | 1,
                UInt8(v >> 7 & 0xFF),
                UInt8(v & 0x7F) << 1 | 1]
    }

    private mutating func writeHeader(_ p: inout [UInt8], pid: UInt16, pusi: Bool, adaptation: Bool) {
        let cc = continuity[pid, default: 0]
        p[0] = 0x47
        p[1] = (pusi ? 0x40 : 0) | UInt8(pid >> 8)
        p[2] = UInt8(pid & 0xFF)
        p[3] = (adaptation ? 0x20 : 0) | 0x10 | cc
        continuity[pid] = (cc + 1) & 0x0F
    }
}
