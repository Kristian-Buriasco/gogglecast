import Foundation
import GogglesProtocol

// ─────────────────────────────────────────────────────────────────────────
// `gvcli stream|replay --dump-telemetry <path>`: appends every inbound
// non-video packet (type 0x00 handshake reply, type 0x01 telemetry, and any
// 0x03/unknown types should they ever appear) to <path> as JSON lines, with
// a best-effort DUML decode (see GogglesProtocol/Telemetry.swift). Purely
// diagnostic -- it never touches the video path, and with the flag absent
// nothing here is instantiated. See docs/telemetry-research.md.
// ─────────────────────────────────────────────────────────────────────────

/// One JSON line. Field names are snake_case and stable so captures stay
/// comparable across tool versions.
public struct TelemetryRecord: Encodable {
    /// Host receive time, Unix epoch seconds.
    public let t: Double
    public let type: Int
    public let seq: Int
    public let session: Int
    /// Full UDP payload (8-byte outer header + body).
    public let len: Int
    public let payload_hex: String
    /// Leading u16 LE fields of the body (window state per udp_protocol.md).
    public let windows: [Int]
    public let duml_offset: Int?
    public let duml_len_prefix: Int?
    public let duml_len_prefix_ok: Bool?
    public let duml_unparsed_tail: Int
    public let duml: [DumlRecord]

    public struct DumlRecord: Encodable {
        public let off: Int
        public let ver: Int
        public let src: String
        public let src_name: String
        public let dst: String
        public let dst_name: String
        public let seq: Int
        public let cmd_type: String
        public let is_response: Bool
        public let ack: Int
        public let encrypt: Int
        /// "SS:II" hex, e.g. "03:43".
        public let cmd: String
        public let set_name: String?
        public let name: String?
        public let payload_len: Int
        public let payload_hex: String
        public let decoded: DecodedRecord?
    }

    public struct DecodedRecord: Encodable {
        public let value: Telemetry.Decoded

        enum Keys: String, CodingKey { case kind, confidence, fields }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(value.kind, forKey: .kind)
            try c.encode(value.confidence, forKey: .confidence)
            switch value {
            case .osdGeneral(let v): try c.encode(v, forKey: .fields)
            case .vtSignalQuality(let v): try c.encode(v, forKey: .fields)
            case .rcPushParam(let v): try c.encode(v, forKey: .fields)
            case .batteryDynamic(let v): try c.encode(v, forKey: .fields)
            case .sdrRTStatus(let v): try c.encode(v, forKey: .fields)
            case .asciiStrings(let v): try c.encode(v, forKey: .fields)
            }
        }
    }

    /// Builds a record from a raw inbound UDP payload. Returns nil if it's
    /// shorter than the 8-byte outer header.
    public static func make(packet: Data, timestamp: Date) -> TelemetryRecord? {
        guard let outer = WireProtocol.parseOuter(packet) else { return nil }
        let a = Telemetry.analyzeBody(outer.body)
        let frames = a.frames.map { f -> DumlRecord in
            let p = f.packet
            return DumlRecord(
                off: f.offset, ver: Int(p.version),
                src: String(format: "%02x", p.sender), src_name: Telemetry.addressName(p.sender),
                dst: String(format: "%02x", p.receiver), dst_name: Telemetry.addressName(p.receiver),
                seq: Int(p.seq), cmd_type: String(format: "%02x", p.cmdType),
                is_response: Telemetry.isResponse(p.cmdType), ack: Int(Telemetry.ackType(p.cmdType)),
                encrypt: Int(Telemetry.encryptType(p.cmdType)),
                cmd: String(format: "%02x:%02x", p.cmdSet, p.cmdId),
                set_name: Telemetry.cmdSetNames[p.cmdSet],
                name: Telemetry.commandName(cmdSet: p.cmdSet, cmdId: p.cmdId),
                payload_len: p.payload.count, payload_hex: Telemetry.hex(p.payload),
                decoded: Telemetry.decode(p).map(DecodedRecord.init(value:))
            )
        }
        return TelemetryRecord(
            t: timestamp.timeIntervalSince1970, type: Int(outer.pktType), seq: Int(outer.seq),
            session: Int(outer.sessionId), len: packet.count, payload_hex: Telemetry.hex(packet),
            windows: a.windowFields.map(Int.init), duml_offset: a.firstFrameOffset,
            duml_len_prefix: a.lengthPrefix.map(Int.init), duml_len_prefix_ok: a.lengthPrefixMatchesRemainder,
            duml_unparsed_tail: a.unparsedTailBytes, duml: frames
        )
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Garbage bytes decoded as Double/Float can be NaN/inf; never let
        // that throw away the whole line.
        e.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return e
    }()

    /// Single-line JSON, no trailing newline.
    public func jsonLine() -> String? {
        guard let d = try? TelemetryRecord.encoder.encode(self) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Appends `TelemetryRecord` JSON lines to a file and keeps per-second
/// counters for the optional `[telem]` stats line. Thread-safe; writes are
/// synchronous `write(2)`s (~10 small lines/s), so nothing is lost when the
/// SIGINT handler calls `exit(0)`.
public final class TelemetryDumpWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    public let path: String
    private var counts: [String: Int] = [:]
    private var packetsThisSecond = 0
    private var totalLines = 0

    /// Opens (creating if needed) `path` for appending.
    public init(path: String) throws {
        self.path = path
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
    }

    /// Whether `pktType` should be dumped: everything except video (0x02)
    /// and our own ack types, which the goggles never send anyway.
    public static func shouldDump(pktType: UInt8) -> Bool {
        pktType != WireProtocol.packetTypeVideo
    }

    /// Records one inbound UDP payload. No-op for video packets.
    public func record(packet: Data, timestamp: Date = Date()) {
        guard packet.count >= 8, TelemetryDumpWriter.shouldDump(pktType: packet[packet.startIndex + 6]),
              let rec = TelemetryRecord.make(packet: packet, timestamp: timestamp),
              let line = rec.jsonLine() else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        totalLines += 1
        packetsThisSecond += 1
        if rec.duml.isEmpty {
            counts[String(format: "t%02x/no-duml", rec.type), default: 0] += 1
        }
        for f in rec.duml {
            counts["\(f.src)>\(f.dst) \(f.cmd)", default: 0] += 1
        }
    }

    /// One-line per-second summary, e.g.
    /// `pkts=10 lines=123 {0e>2a 09:08 x10, ...}`. Resets the counters.
    public func snapshotAndReset() -> String {
        lock.lock()
        defer { lock.unlock() }
        let body = counts.keys.sorted().map { "\($0) x\(counts[$0] ?? 0)" }.joined(separator: ", ")
        let line = "pkts=\(packetsThisSecond) lines=\(totalLines) {\(body)}"
        counts.removeAll(keepingCapacity: true)
        packetsThisSecond = 0
        return line
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}
