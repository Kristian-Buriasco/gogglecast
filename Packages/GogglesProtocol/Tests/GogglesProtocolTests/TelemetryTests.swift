// Tests for Telemetry.swift (research-grade DUML telemetry decoding).
//
// Real-hardware vectors: the two DUML frames printed in
// samuelsadok/dji_protocol usb_mobile_protocol.md ("Starting the video
// stream", captured from a DJI Goggles N3 + O4 Air Unit Pro). Both validate
// with this package's CRC-8/CRC-16 seeds. NOTE: that doc's "DUML CRC16"
// column (`92 3a`, `34 18`) is actually trailing bytes AFTER the frame; the
// real CRC-16 is the last two bytes of its "payload" column (`d0 93`,
// `58 a6`). Everything else here is synthetic (built with DUML.build).

import Testing
import Foundation
@testable import GogglesProtocol

private func hexData(_ s: String) -> Data {
    let clean = s.replacingOccurrences(of: " ", with: "")
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// N3 -> "camcap_common" pub/sub subscribe (00:99), 45 bytes.
private let n3Frame0099 = hexData(
    "55 2d 04 f2 02 28 f3 fe 40 00 99 02 02 00 00 d5 07 00 00 00 00 00 13 00 0d 00 " +
    "63 61 6d 63 61 70 5f 63 6f 6d 6d 6f 6e 00 00 00 00 d0 93"
)
/// N3 query device information "APP" (00:88), 27 bytes.
private let n3Frame0088 = hexData(
    "55 1b 04 75 02 3c f4 fe 40 00 88 17 00 00 23 00 41 50 50 00 00 00 00 00 02 58 a6"
)

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

@Suite struct TelemetryScanTests {

    @Test func realN3FramesValidate() {
        let frames = Telemetry.scanFrames(in: n3Frame0099 + n3Frame0088)
        #expect(frames.count == 2)
        #expect(frames[0].offset == 0)
        #expect(frames[1].offset == 45)
        let a = frames[0].packet
        #expect(a.sender == 0x02 && a.receiver == 0x28)
        #expect(a.cmdSet == 0x00 && a.cmdId == 0x99)
        #expect(a.seq == 0xFEF3)
        #expect(a.payload.count == 45 - 13)
        let b = frames[1].packet
        #expect(b.receiver == 0x3C && b.cmdId == 0x88)
    }

    @Test func scanSkipsJunkAndCorruptFrames() {
        var corrupt = n3Frame0088
        corrupt[corrupt.startIndex + 15] ^= 0xFF // payload byte -> CRC-16 fails
        // Leading junk containing stray 0x55 bytes, a corrupt frame, then a good one.
        let buf = Data([0x55, 0x00, 0x55, 0x13, 0x04]) + corrupt + n3Frame0099
        let frames = Telemetry.scanFrames(in: buf)
        #expect(frames.count == 1)
        #expect(frames[0].offset == 5 + corrupt.count)
        #expect(frames[0].packet.cmdId == 0x99)
    }

    @Test func documentedType01Layout() {
        // udp_protocol.md: 20 bytes window state, type-5 resend list
        // (u16 count = 0), u16 remaining-MB length, MB chunks.
        var body: [UInt8] = []
        for v in [0x1000, 0x1040, 0, 0, 0x2000, 0x2000, 0, 0, 0x3000, 0x3008] { body += le16(v) }
        body += le16(0)
        let mb = n3Frame0088 + n3Frame0099
        body += le16(mb.count)
        let a = Telemetry.analyzeBody(Data(body) + mb)
        #expect(a.windowFields.prefix(2) == [0x1000, 0x1040])
        #expect(a.windowFields.count == 10)
        #expect(a.firstFrameOffset == 24)
        #expect(a.frames.count == 2)
        #expect(a.lengthPrefix == UInt16(mb.count))
        #expect(a.lengthPrefixMatchesRemainder == true)
        #expect(a.unparsedTailBytes == 0)
    }

    @Test func prototypeOutboundLayoutRoundTrips() {
        // Our own I-frame request: 24 zero bytes + u16 len + DUML at body 26.
        let pkt = WireProtocol.requestIFrameTelemetry(seq: 8, sessionId: 0x1234)
        let outer = WireProtocol.parseOuter(pkt)!
        let a = Telemetry.analyzeBody(outer.body)
        #expect(a.firstFrameOffset == 26)
        #expect(a.lengthPrefix == 13)
        #expect(a.lengthPrefixMatchesRemainder == true)
        #expect(a.frames.first?.packet.cmdSet == 0x02)
        #expect(a.frames.first?.packet.cmdId == 0xB3)
    }

    @Test func noFramesInWindowOnlyBody() {
        let a = Telemetry.analyzeBody(Data(repeating: 0, count: 24))
        #expect(a.frames.isEmpty)
        #expect(a.lengthPrefix == nil)
        #expect(a.lengthPrefixMatchesRemainder == nil)
        #expect(a.unparsedTailBytes == 0)
    }
}

@Suite struct TelemetryNamingTests {
    @Test func addressNames() {
        #expect(Telemetry.addressName(0xBC) == "sig_cvt#5")   // goggles (observed)
        #expect(Telemetry.addressName(0x2A) == "pc#1")        // our host address
        #expect(Telemetry.addressName(0x09) == "hd_link_air#0") // air unit (observed)
        #expect(Telemetry.addressName(0x0E) == "hd_link_gnd#0")
    }

    @Test func cmdTypeBits() {
        #expect(Telemetry.isResponse(0xC0))
        #expect(!Telemetry.isResponse(0x40))
        #expect(Telemetry.ackType(0x40) == 2)
        #expect(Telemetry.ackType(0x20) == 1)
        #expect(Telemetry.encryptType(0x43) == 3)
    }

    @Test func commandNamesAndHex() {
        #expect(Telemetry.commandName(cmdSet: 0x03, cmdId: 0x43) == "flight_controller.osd_general_data_push")
        #expect(Telemetry.commandName(cmdSet: 0x7F, cmdId: 0x7F) == nil)
        #expect(Telemetry.hex(Data([0x00, 0xAB, 0x5F])) == "00ab5f")
    }
}

@Suite struct TelemetryTypedDecodeTests {

    private func frame(_ set: UInt8, _ id: UInt8, _ payload: [UInt8]) -> DUML.DumlPacket {
        let raw = DUML.build(sender: 0x03, receiver: 0x2A, seq: 1, cmdType: 0x00, cmdSet: set, cmdId: id, payload: Data(payload))
        return Telemetry.scanFrames(in: raw)[0].packet
    }

    @Test func osdGeneralLegacyLayout() {
        var p = [UInt8](repeating: 0, count: 50)
        func put(_ o: Int, _ bytes: [UInt8]) { for (k, b) in bytes.enumerated() { p[o + k] = b } }
        func f64(_ d: Double) -> [UInt8] { withUnsafeBytes(of: d.bitPattern.littleEndian, Array.init) }
        func i16(_ v: Int16) -> [UInt8] { le16(Int(UInt16(bitPattern: v))) }
        put(0, f64(4.70 * .pi / 180))   // lon
        put(8, f64(50.88 * .pi / 180))  // lat
        put(16, i16(1234))              // 123.4 m
        put(18, i16(-25))               // -2.5 m/s
        put(24, i16(-150))              // pitch -15.0
        put(28, i16(1795))              // yaw 179.5
        p[30] = 0x86                    // mode 6 + high bit
        p[36] = 14                      // sats
        p[40] = 77                      // battery %
        guard case .osdGeneral(let v)? = Telemetry.decode(frame(0x03, 0x43, p)) else {
            Issue.record("expected osdGeneral"); return
        }
        #expect(abs(v.longitudeDeg - 4.70) < 1e-9)
        #expect(abs(v.latitudeDeg - 50.88) < 1e-9)
        #expect(v.relativeHeightM == 123.4)
        #expect(v.velocityX == -2.5)
        #expect(v.pitchDeg == -15.0)
        #expect(v.yawDeg == 179.5)
        #expect(v.flightMode == 6)
        #expect(v.gpsSatellites == 14)
        #expect(v.batteryPercent == 77)
        // Wrong size -> no typed decode.
        #expect(Telemetry.decodeOSDGeneral(Data(count: 49)) == nil)
    }

    @Test func vtSignalQuality() {
        guard case .vtSignalQuality(let v)? = Telemetry.decode(frame(0x09, 0x08, [0x80 | 87])) else {
            Issue.record("expected vtSignalQuality"); return
        }
        #expect(v.upSignalQuality == 87)
        #expect(v.rawByte == 0xD7)
    }

    @Test func rcPushParam() {
        let p = le16(364) + le16(1024) + le16(1684) + le16(1000) + le16(0) + [0x01, 0x08, 0x00]
        guard case .rcPushParam(let v)? = Telemetry.decode(frame(0x06, 0x05, p)) else {
            Issue.record("expected rcPushParam"); return
        }
        #expect(v.aileron == 364 && v.elevator == 1024 && v.throttle == 1684 && v.rudder == 1000)
        #expect(v.buttons1 == 0x08)
    }

    @Test func batteryDynamicOneBytePrefix() {
        func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        var p: [UInt8] = [0x00]
        p += u32(15_400) + u32(UInt32(bitPattern: -2_500)) + u32(3_850) + u32(2_900)
        p += le16(312) + [4, 75] + [UInt8](repeating: 0, count: 8) + [0x01]
        #expect(p.count == 30)
        guard case .batteryDynamic(let v)? = Telemetry.decode(frame(0x0D, 0x02, p)) else {
            Issue.record("expected batteryDynamic"); return
        }
        #expect(v.voltageMV == 15_400)
        #expect(v.currentMA == -2_500)
        #expect(v.remainCapacityMAh == 2_900)
        #expect(v.cellCount == 4)
        #expect(v.stateOfChargePercent == 75)
    }

    @Test func sdrRTStatusEntries() {
        func entry(_ name: String, _ value: Float) -> [UInt8] {
            var n = Array(name.utf8); n += [UInt8](repeating: 0, count: 8 - n.count)
            return n + withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        }
        let p = entry("snr", 21.5) + entry("rssi_a", -61)
        guard case .sdrRTStatus(let v)? = Telemetry.decode(frame(0x09, 0x25, p)) else {
            Issue.record("expected sdrRTStatus"); return
        }
        #expect(v == [.init(name: "snr", value: 21.5), .init(name: "rssi_a", value: -61)])
    }

    @Test func pubSubFallsBackToAsciiStrings() {
        let pkt = Telemetry.scanFrames(in: n3Frame0099)[0].packet
        #expect(Telemetry.decode(pkt) == .asciiStrings(["camcap_common"]))
        // Unknown cmd with no ASCII -> nil.
        #expect(Telemetry.decode(frame(0x55, 0x01, [0x00, 0x01, 0x02])) == nil)
    }
}
