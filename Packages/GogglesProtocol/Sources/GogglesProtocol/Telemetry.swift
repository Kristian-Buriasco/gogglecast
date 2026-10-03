import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Telemetry research support: best-effort decoding of the DUML ("DJI MB
// protocol") frames the goggles embed in inbound type-0x01 packets on UDP
// 9003. See docs/telemetry-research.md for what is documented vs. guessed.
//
// Everything here is READ-ONLY / diagnostic. Nothing in the video path
// depends on it, and every decode is "best effort": an unrecognized frame
// is still reported (addresses, cmd set/id, raw payload hex), it just has
// no typed `decoded` value.
//
// Confidence levels used below:
//   - documented:  layout taken from samuelsadok/dji_protocol udp_protocol.md
//                  (Mavic Pro over WiFi/RNDIS -- NOT verified on Goggles 3).
//   - legacy:      payload layout as described by the o-gs/dji-firmware-tools
//                  Wireshark dissector for older platforms (P3/Mavic/Spark
//                  era). Goggles 3 / O4-era firmware may use a different
//                  layout or not send the message at all.
//   - unverified:  nobody has confirmed this against Goggles 3 traffic yet.
// ─────────────────────────────────────────────────────────────────────────

public enum Telemetry {

    // MARK: - Silent, CRC-validated DUML scan

    /// A DUML frame located at byte `offset` of the scanned buffer.
    public struct ScannedFrame: Equatable {
        public let offset: Int
        public let packet: DUML.DumlPacket
    }

    /// Finds every CRC-valid (CRC-8 header AND CRC-16 whole-frame) DUML
    /// frame anywhere in `data`, in order, without logging.
    ///
    /// Unlike `DUML.parseStream` this never reports skipped bytes through
    /// `WireProtocol.malformedFrameHandler` -- the type-0x01 body begins with
    /// ~24 bytes of non-DUML window state, so a skip-and-log scan would spam
    /// stderr 10x/second. Requiring both CRCs makes a false positive in
    /// random bytes vanishingly unlikely (~2^-24 per candidate 0x55).
    public static func scanFrames(in data: Data) -> [ScannedFrame] {
        let b = [UInt8](data)
        var out: [ScannedFrame] = []
        var i = 0
        while i + DUML.minLen <= b.count {
            guard b[i] == DUML.magic else { i += 1; continue }
            let raw = UInt16(b[i + 1]) | (UInt16(b[i + 2]) << 8)
            let length = Int(raw & 0x03FF)
            guard length >= DUML.minLen, i + length <= b.count,
                  DUML.crc8(Data(b[i..<(i + 3)])) == b[i + 3] else { i += 1; continue }
            let want = UInt16(b[i + length - 2]) | (UInt16(b[i + length - 1]) << 8)
            guard DUML.crc16(Data(b[i..<(i + length - 2)])) == want else { i += 1; continue }
            let packet = DUML.DumlPacket(
                version: UInt8(raw >> 10), sender: b[i + 4], receiver: b[i + 5],
                seq: UInt16(b[i + 6]) | (UInt16(b[i + 7]) << 8),
                cmdType: b[i + 8], cmdSet: b[i + 9], cmdId: b[i + 10],
                payload: Data(b[(i + 11)..<(i + length - 2)]),
                raw: Data(b[i..<(i + length)])
            )
            out.append(ScannedFrame(offset: i, packet: packet))
            i += length
        }
        return out
    }

    // MARK: - Type-0x01 body analysis

    /// Result of `analyzeBody`. `body` is everything after the 8-byte outer
    /// header (i.e. `WireProtocol.ParsedOuter.body`).
    public struct BodyAnalysis: Equatable {
        /// The leading little-endian u16 fields (up to 10). Per
        /// udp_protocol.md (documented, Mavic Pro): [0..3] type-2 send
        /// window start/end/resend1/resend2, [4..7] the same for type 3,
        /// [8..9] type-5 receive window start/end.
        public let windowFields: [UInt16]
        /// Every CRC-valid DUML frame found anywhere in the body.
        public let frames: [ScannedFrame]
        /// Offset of the first DUML frame, if any.
        public var firstFrameOffset: Int? { frames.first?.offset }
        /// The u16 LE immediately before the first frame. udp_protocol.md
        /// documents a "total length of the remaining MB payload" field
        /// there; the Python prototype's outbound builder assumes it sits at
        /// body offset 24. `nil` if there's no frame or no room for it.
        public let lengthPrefix: UInt16?
        /// Whether `lengthPrefix` equals the number of bytes from the first
        /// frame to the end of the body -- i.e. whether the documented
        /// "length then MB chunks" layout holds on this firmware.
        public let lengthPrefixMatchesRemainder: Bool?
        /// Bytes from the first frame offset to the end of the body that are
        /// NOT covered by a CRC-valid frame (0 == fully decoded).
        public let unparsedTailBytes: Int
    }

    public static func analyzeBody(_ body: Data) -> BodyAnalysis {
        let b = [UInt8](body)
        var windows: [UInt16] = []
        var o = 0
        while o + 1 < b.count && windows.count < 10 {
            windows.append(UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
            o += 2
        }
        let frames = scanFrames(in: body)
        var prefix: UInt16?
        var matches: Bool?
        var unparsed = 0
        if let first = frames.first {
            if first.offset >= 2 {
                let p = UInt16(b[first.offset - 2]) | (UInt16(b[first.offset - 1]) << 8)
                prefix = p
                matches = Int(p) == b.count - first.offset
            }
            let covered = frames.reduce(0) { $0 + $1.packet.raw.count }
            unparsed = (b.count - first.offset) - covered
        }
        return BodyAnalysis(
            windowFields: windows, frames: frames, lengthPrefix: prefix,
            lengthPrefixMatchesRemainder: matches, unparsedTailBytes: unparsed
        )
    }

    // MARK: - Header interpretation

    /// DUML address byte: low 5 bits = device type, high 3 bits = index
    /// (observed: goggles 0xBC/0x3C, app/PC 0x2A, air unit 0x09/0x29).
    public static func deviceType(_ address: UInt8) -> UInt8 { address & 0x1F }
    public static func deviceIndex(_ address: UInt8) -> UInt8 { address >> 5 }

    /// Device-type names (low 5 bits of an address). Community naming
    /// (o-gs/dji-firmware-tools); several types are reused differently on
    /// newer products, so treat as a hint.
    public static let deviceTypeNames: [String] = [
        "any", "camera", "app", "flight_controller", "gimbal", "center_board",
        "remote_control", "wifi_air", "dm36x_air", "hd_link_air", "pc",
        "battery", "esc", "dm36x_gnd", "hd_link_gnd", "usb_s2p_air",
        "usb_s2p_gnd", "monocular", "binocular", "fpga_air", "fpga_gnd",
        "simulator", "base_station", "onboard_computer", "rc_battery", "imu",
        "gps_rtk", "wifi_gnd", "sig_cvt", "pmu", "unknown30", "last",
    ]

    /// e.g. `0xBC` -> "sig_cvt#5".
    public static func addressName(_ address: UInt8) -> String {
        "\(deviceTypeNames[Int(deviceType(address))])#\(deviceIndex(address))"
    }

    /// Byte 8 of a DUML frame: bit 7 = response, bits 5-6 = ack type
    /// (0 none, 1 ack-before-exec/push, 2 ack-after-exec), bits 0-3 =
    /// encryption type (0 = none).
    public static func isResponse(_ cmdType: UInt8) -> Bool { cmdType & 0x80 != 0 }
    public static func ackType(_ cmdType: UInt8) -> UInt8 { (cmdType >> 5) & 0x03 }
    public static func encryptType(_ cmdType: UInt8) -> UInt8 { cmdType & 0x0F }

    public static let cmdSetNames: [UInt8: String] = [
        0x00: "general", 0x01: "special", 0x02: "camera", 0x03: "flight_controller",
        0x04: "gimbal", 0x05: "center_board", 0x06: "remote_control", 0x07: "wifi",
        0x08: "dm36x", 0x09: "hd_link", 0x0A: "vision", 0x0B: "simulator",
        0x0C: "esc", 0x0D: "battery", 0x0E: "data_logger", 0x0F: "rtk",
        0x10: "automation", 0x11: "adsb", 0x12: "bvision", 0x13: "fpga_air",
        0x14: "fpga_gnd", 0x15: "glass", 0x16: "mavlink", 0x17: "watch",
        0x1C: "rm", 0x21: "max",
    ]

    /// Curated command names likely relevant to goggles/air-unit telemetry.
    /// Key = (cmdSet << 8) | cmdId. Not exhaustive -- see
    /// docs/telemetry-research.md for sources and for the full dissector.
    public static let commandNames: [UInt16: String] = [
        0x0000: "general.ping",
        0x0001: "general.version_inquiry",
        0x000C: "general.get_device_state",
        0x000E: "general.heartbeat_log_message",
        0x0082: "general.goggles_status_push(observed on IF4, name unknown)",
        0x0088: "general.query_device_information",
        0x0099: "general.united_pub_sub_agent",
        0x00FF: "general.query_device_info",
        0x0280: "camera.state_info_push",
        0x02B3: "camera.app_request_i_frame",
        0x0343: "flight_controller.osd_general_data_push",
        0x0344: "flight_controller.osd_home_point_push",
        0x0405: "gimbal.params_push",
        0x0605: "remote_control.param_push",
        0x0651: "remote_control.push_to_glass",
        0x0832: "dm36x.sdr_data_report_push",
        0x0901: "hd_link.osd_general_data",
        0x0902: "hd_link.osd_home_point",
        0x0908: "hd_link.vt_signal_quality_push",
        0x090B: "hd_link.device_status_push",
        0x0911: "hd_link.wl_env_quality_push",
        0x0915: "hd_link.max_video_bandwidth_push",
        0x0922: "hd_link.sdr_dl_auto_vt_info_push",
        0x0924: "hd_link.sdr_uav_rt_status_push",
        0x0925: "hd_link.sdr_gnd_rt_status_push",
        0x0930: "hd_link.sdr_wireless_env_state",
        0x0936: "hd_link.sdr_liveview_rate_ind",
        0x0937: "hd_link.abnormal_event_ind",
        0x093F: "hd_link.rc_conn_status_push",
        0x0952: "hd_link.power_status_push",
        0x0D01: "battery.static_data",
        0x0D02: "battery.dynamic_data_push",
        0x0D03: "battery.cell_voltage_push",
        0x0D06: "battery.push_common_info",
    ]

    public static func commandName(cmdSet: UInt8, cmdId: UInt8) -> String? {
        commandNames[(UInt16(cmdSet) << 8) | UInt16(cmdId)]
    }

    // MARK: - Typed decoders (legacy layouts, UNVERIFIED on Goggles 3)

    /// FC "OSD General Data" (03:43). Legacy layout, 50 or 55 bytes.
    /// Lat/lon are radians in the wire format; converted to degrees here.
    public struct OSDGeneral: Equatable, Codable {
        public let longitudeDeg: Double
        public let latitudeDeg: Double
        /// Height above takeoff, metres (wire: int16, 0.1 m).
        public let relativeHeightM: Double
        /// Ground speed components, m/s (wire: int16, 0.1 m/s).
        public let velocityX: Double
        public let velocityY: Double
        public let velocityZ: Double
        /// Attitude, degrees (wire: int16, 0.1 deg).
        public let pitchDeg: Double
        public let rollDeg: Double
        public let yawDeg: Double
        /// Low 7 bits of byte 30 = flight mode ("flyc_state").
        public let flightMode: UInt8
        public let controllerState: UInt32
        public let gpsSatellites: UInt8
        /// Byte 40, percent.
        public let batteryPercent: UInt8
        public let productType: UInt8
    }

    public static func decodeOSDGeneral(_ p: Data) -> OSDGeneral? {
        guard p.count == 50 || p.count == 55 else { return nil }
        let r = ByteReader(p)
        let rad2deg = 180.0 / Double.pi
        return OSDGeneral(
            longitudeDeg: r.f64(0) * rad2deg,
            latitudeDeg: r.f64(8) * rad2deg,
            relativeHeightM: Double(r.i16(16)) / 10,
            velocityX: Double(r.i16(18)) / 10,
            velocityY: Double(r.i16(20)) / 10,
            velocityZ: Double(r.i16(22)) / 10,
            pitchDeg: Double(r.i16(24)) / 10,
            rollDeg: Double(r.i16(26)) / 10,
            yawDeg: Double(r.i16(28)) / 10,
            flightMode: r.u8(30) & 0x7F,
            controllerState: r.u32(32),
            gpsSatellites: r.u8(36),
            batteryPercent: r.u8(40),
            productType: r.u8(48)
        )
    }

    /// HD link "VT Signal Quality" push (09:08): 1 byte, low 7 bits =
    /// uplink (RC/goggles -> air) signal quality, presumably 0..100.
    public struct VTSignalQuality: Equatable, Codable {
        public let upSignalQuality: UInt8
        public let rawByte: UInt8
    }

    public static func decodeVTSignalQuality(_ p: Data) -> VTSignalQuality? {
        guard p.count == 1 else { return nil }
        let v = p[p.startIndex]
        return VTSignalQuality(upSignalQuality: v & 0x7F, rawByte: v)
    }

    /// RC "Parameter Push" (06:05): stick channels. Legacy range is
    /// 364..1684 with 1024 centre.
    public struct RCPushParam: Equatable, Codable {
        public let aileron: UInt16
        public let elevator: UInt16
        public let throttle: UInt16
        public let rudder: UInt16
        public let gyroValue: UInt16
        public let wheelInfo: UInt8
        public let buttons1: UInt8
        public let buttons2: UInt8
    }

    public static func decodeRCPushParam(_ p: Data) -> RCPushParam? {
        guard p.count == 13 || p.count == 14 else { return nil }
        let r = ByteReader(p)
        return RCPushParam(
            aileron: r.u16(0), elevator: r.u16(2), throttle: r.u16(4), rudder: r.u16(6),
            gyroValue: r.u16(8), wheelInfo: r.u8(10), buttons1: r.u8(11), buttons2: r.u8(12)
        )
    }

    /// Smart battery "Dynamic Data" (0D:02). Legacy layout has a 1- or
    /// 2-byte prefix before the voltage (dissector notes the ambiguity).
    public struct BatteryDynamic: Equatable, Codable {
        public let voltageMV: UInt32
        public let currentMA: Int32
        public let fullCapacityMAh: UInt32
        public let remainCapacityMAh: UInt32
        /// Wire unit uncertain (0.1 degC on some platforms).
        public let temperatureRaw: UInt16
        public let cellCount: UInt8
        public let stateOfChargePercent: UInt8
    }

    public static func decodeBatteryDynamic(_ p: Data) -> BatteryDynamic? {
        guard p.count >= 30 else { return nil }
        let r = ByteReader(p)
        let o = p.count == 32 ? 2 : 1
        return BatteryDynamic(
            voltageMV: r.u32(o), currentMA: Int32(bitPattern: r.u32(o + 4)),
            fullCapacityMAh: r.u32(o + 8), remainCapacityMAh: r.u32(o + 12),
            temperatureRaw: r.u16(o + 16), cellCount: r.u8(o + 18),
            stateOfChargePercent: r.u8(o + 19)
        )
    }

    /// HD link "SDR RT Status" push (09:24 air / 09:25 ground): repeated
    /// 12-byte entries of an 8-byte NUL-padded ASCII name + float32 value.
    /// Self-describing, so this is the most promising link-quality source
    /// if the goggles forward it.
    public struct SDRStatusEntry: Equatable, Codable {
        public let name: String
        public let value: Float
    }

    public static func decodeSDRRTStatus(_ p: Data) -> [SDRStatusEntry]? {
        guard !p.isEmpty, p.count % 12 == 0 else { return nil }
        let r = ByteReader(p)
        var out: [SDRStatusEntry] = []
        for k in 0..<(p.count / 12) {
            let nameBytes = (0..<8).map { r.u8(k * 12 + $0) }.prefix { $0 != 0 }
            guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            let name = String(decoding: nameBytes, as: UTF8.self)
            out.append(SDRStatusEntry(name: name, value: Float(bitPattern: r.u32(k * 12 + 8))))
        }
        return out
    }

    /// A typed decode of a known message. `confidence` is always one of the
    /// strings documented at the top of this file.
    public enum Decoded: Equatable {
        case osdGeneral(OSDGeneral)
        case vtSignalQuality(VTSignalQuality)
        case rcPushParam(RCPushParam)
        case batteryDynamic(BatteryDynamic)
        case sdrRTStatus([SDRStatusEntry])
        /// 00:99 pub/sub frames and anything else carrying printable ASCII
        /// runs (topic names like "camcap_common"); not a layout decode.
        case asciiStrings([String])

        public var kind: String {
            switch self {
            case .osdGeneral: return "fc_osd_general"
            case .vtSignalQuality: return "hd_link_vt_signal_quality"
            case .rcPushParam: return "rc_push_param"
            case .batteryDynamic: return "battery_dynamic"
            case .sdrRTStatus: return "hd_link_sdr_rt_status"
            case .asciiStrings: return "ascii_strings"
            }
        }

        public var confidence: String {
            switch self {
            case .asciiStrings: return "heuristic"
            default: return "legacy-layout, unverified on Goggles 3"
            }
        }
    }

    /// Best-effort typed decode, keyed on cmd set/id only (direction and
    /// request/response bit are NOT checked -- a request with a payload of
    /// exactly the right size would be mis-decoded, so always cross-check
    /// `cmdType` in the dump). Frames whose payload size doesn't match the
    /// legacy layout fall through to `.asciiStrings` or nil.
    public static func decode(_ p: DUML.DumlPacket) -> Decoded? {
        switch (p.cmdSet, p.cmdId) {
        case (0x03, 0x43), (0x09, 0x01):
            if let v = decodeOSDGeneral(p.payload) { return .osdGeneral(v) }
        case (0x09, 0x08):
            if let v = decodeVTSignalQuality(p.payload) { return .vtSignalQuality(v) }
        case (0x06, 0x05):
            if let v = decodeRCPushParam(p.payload) { return .rcPushParam(v) }
        case (0x0D, 0x02):
            if let v = decodeBatteryDynamic(p.payload) { return .batteryDynamic(v) }
        case (0x09, 0x24), (0x09, 0x25):
            if let v = decodeSDRRTStatus(p.payload) { return .sdrRTStatus(v) }
        default:
            break
        }
        let strings = asciiRuns(p.payload)
        return strings.isEmpty ? nil : .asciiStrings(strings)
    }

    /// Printable-ASCII runs of at least `minLength` bytes.
    public static func asciiRuns(_ data: Data, minLength: Int = 4) -> [String] {
        var out: [String] = []
        var run: [UInt8] = []
        func flush() {
            if run.count >= minLength { out.append(String(decoding: run, as: UTF8.self)) }
            run.removeAll(keepingCapacity: true)
        }
        for byte in data {
            if byte >= 0x20 && byte < 0x7F { run.append(byte) } else { flush() }
        }
        flush()
        return out
    }

    // MARK: - Helpers

    /// Little-endian reader over a `Data` that may be a slice.
    struct ByteReader {
        let b: [UInt8]
        init(_ d: Data) { b = [UInt8](d) }
        func u8(_ o: Int) -> UInt8 { b[o] }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | (UInt32(u16(o + 2)) << 16) }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | (UInt64(u32(o + 4)) << 32) }
        func f64(_ o: Int) -> Double { Double(bitPattern: u64(o)) }
    }

    /// Lowercase hex, no separators.
    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
