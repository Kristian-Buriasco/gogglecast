import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Provenance (design §8.6): every magic constant in this file was derived
// empirically by capturing/replaying traffic against ONE physical goggles
// unit:
//
//   firmware:   zv300 gl Ver.02
//   bcdDevice:  0x0504
//
// A firmware update on the goggles can invalidate any of this (handshake
// body, ack tail, packet-type numbers, DUML CRC seeds, I-frame-request
// parameters) without warning. If a future unit/firmware stops working,
// suspect these constants first, not the framing logic around them. This
// is also why unknown/unrecognized packet types are logged rather than
// silently dropped -- see `WireProtocol.logUnknownPacketType` below.
// ─────────────────────────────────────────────────────────────────────────

/// Byte-exact Swift port of the application wire protocol carried over
/// UDP 9003 (Python prototype's `stream.py`, design §3.3) plus the DUML
/// control-frame codec (`duml.py`, design §3.4). Pure Foundation only --
/// no networking frameworks, matching the rest of this package.
///
/// Every magic constant used anywhere in this task (packet-type bytes,
/// the handshake body, the ack tail, the DUML CRC seeds, the I-frame
/// request's fixed sender/receiver/seq/cmd fields) lives in this one file
/// per design §8.6, rather than scattered across call sites.
public enum WireProtocol {

    // MARK: - §3.3 outer-header packet types

    /// Packet-type byte at outer-header offset 6. Handshake, sent once at
    /// connect and re-sent on a 2s data-silence timeout (resend logic is a
    /// later task).
    public static let packetTypeHandshake: UInt8 = 0x00
    /// Telemetry (used in this task only for the best-effort I-frame
    /// request DUML frame).
    public static let packetTypeTelemetry: UInt8 = 0x01
    /// Video fragment. Reassembly is explicitly out of scope for this
    /// task (design §3.3 / task 1.3) -- `buildOuter` still supports this
    /// type since it's shared infrastructure video packets ride on top
    /// of, but no reassembly logic lives here.
    public static let packetTypeVideo: UInt8 = 0x02
    /// Ack, primary observed value. Sent once per completed video frame,
    /// covering that frame's fragment sequence range.
    public static let packetTypeAck: UInt8 = 0x04
    /// Ack, alternate observed value (design §3.3 lists both 0x04 and
    /// 0x06 as ack). `buildAck` below always emits 0x04, matching
    /// `stream.py`'s `build_ack`, which is the only ack-building call
    /// site in the prototype -- 0x06 is recorded here purely so an
    /// inbound-packet classifier (a later task) can recognize both
    /// without treating 0x06 as "unknown".
    public static let packetTypeAckAlt: UInt8 = 0x06

    // MARK: - §3.3 handshake (type 0x00)

    /// The 40-byte handshake body, observed on the wire. Combined with
    /// the 8-byte outer header via `buildHandshake`/`buildOuter`, this
    /// produces the 48-byte handshake packet sent once at connect and
    /// re-sent whenever no data has arrived for 2s.
    public static let handshakeBody: Data = Data([
        0xd0, 0xe9, 0x64, 0x00, 0x64, 0x00, 0xc0, 0x05, 0x14, 0x00, 0x00, 0x0a, 0x00, 0x64, 0x00, 0x64,
        0x00, 0xc0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00, 0x64, 0x00, 0xc0, 0x05, 0x14, 0x00,
        0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x0a, 0x02,
    ])

    // MARK: - §3.3 ack (type 0x04)

    /// The 18-byte constant tail of the 22-byte ack body (bytes 4..21;
    /// bytes 0..3 are the start/end sequence range). Observed on the
    /// wire, meaning unchanged from packet to packet.
    public static let ackTail: Data = Data([
        0x00, 0x00, 0xd0, 0xe9, 0xd0, 0xe9, 0x00, 0x00, 0xd0, 0xe9, 0xd8, 0xe9, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])

    // MARK: - §3.4 DUML CRC seeds

    /// CRC-8 seed for DUML's 3-byte header check (`duml.crc8`'s default).
    public static let dumlCRC8Seed: UInt8 = 0x77
    /// CRC-16 seed for DUML's whole-frame check (`duml.crc16`'s default).
    public static let dumlCRC16Seed: UInt16 = 0x3692

    // MARK: - §3.4 I-frame request (best-effort, non-functional today)

    /// Fixed parameters of `send_request_iframe`'s DUML call in the
    /// Python prototype -- the only DUML frame this task needs to build.
    /// `receiver` is exposed as a parameter on `requestIFrameDUMLFrame`
    /// (matching the Python default arg) rather than baked in, but the
    /// observed value is recorded here.
    public static let iframeRequestSender: UInt8 = 0x2A
    public static let iframeRequestReceiver: UInt8 = 0xBC
    public static let iframeRequestSeq: UInt16 = 0x9000
    public static let iframeRequestCmdType: UInt8 = 0x40
    public static let iframeRequestCmdSet: UInt8 = 0x02
    public static let iframeRequestCmdId: UInt8 = 0xB3

    // MARK: - §3.3 build_outer

    /// Builds the 8-byte outer header + body. Matches Python
    /// `stream.build_outer`.
    ///
    /// `sessionId` is a required parameter, not generated here: the
    /// Python prototype's `SESSION_ID` was a fixed-per-process module
    /// global seeded once via `random.randint(1, 0xFFFE)` at import time.
    /// Hardcoding or regenerating a session id per call would reproduce
    /// an observed bug (IDR delivery breaking on reconnect because the
    /// goggles saw a stale/reused session id). Generating the random
    /// session id once per connection is the caller's job -- see
    /// `randomSessionId()` below, meant to be called exactly once when a
    /// connection/session object is created (a later task).
    public static func buildOuter(pktType: UInt8, seq: UInt16, body: Data, sessionId: UInt16) -> Data {
        let totalLen = UInt16(8 + body.count) | 0x8000
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = UInt8(totalLen & 0xFF)
        header[1] = UInt8((totalLen >> 8) & 0xFF)
        header[2] = UInt8(sessionId & 0xFF)
        header[3] = UInt8((sessionId >> 8) & 0xFF)
        header[4] = UInt8(seq & 0xFF)
        header[5] = UInt8((seq >> 8) & 0xFF)
        header[6] = pktType
        var x: UInt8 = 0
        for i in 0..<7 {
            x ^= header[i]
        }
        header[7] = x
        return Data(header) + body
    }

    /// A decoded 8-byte outer header plus the body bytes that follow it.
    /// Counterpart to `buildOuter` for the receive path (task 1.4): a
    /// transport hands raw inbound UDP-payload bytes to `parseOuter`, which
    /// splits off the fixed header fields so the caller (DUML telemetry
    /// parsing, `FrameReassembler`, an ack-tracking receive loop, etc.) can
    /// dispatch on `pktType` without re-deriving header offsets itself.
    public struct ParsedOuter: Equatable {
        /// Raw little-endian value of header bytes 0..1, including the
        /// observed 0x8000 high bit `buildOuter` always sets -- not
        /// stripped here, so a caller that cares can mask it off itself.
        public let totalLen: UInt16
        public let sessionId: UInt16
        public let seq: UInt16
        public let pktType: UInt8
        /// The XOR checksum byte at header offset 7. Not verified by
        /// `parseOuter` itself (no observed rejection behavior for a bad
        /// checksum has been characterized against real hardware yet) --
        /// exposed so a caller can check it if desired.
        public let checksum: UInt8
        /// Every byte after the 8-byte header -- i.e. what design §5.2
        /// calls "outer-header offset 8", and exactly what
        /// `FrameReassembler.process(videoPayload:receivedAt:)` expects for
        /// a video (`pktType == packetTypeVideo`) packet.
        public let body: Data
    }

    /// Parses the 8-byte outer header + body from a raw inbound UDP-payload
    /// packet (design §3.3). Returns `nil` if `packet` is shorter than the
    /// 8-byte header. Matches `buildOuter`'s field layout byte-for-byte
    /// (little-endian sessionId/seq/totalLen at offsets 0-1/2-3/4-5,
    /// pktType at offset 6, checksum at offset 7).
    public static func parseOuter(_ packet: Data) -> ParsedOuter? {
        guard packet.count >= 8 else { return nil }
        let bytes = [UInt8](packet)
        let totalLen = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let sessionId = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let seq = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        let pktType = bytes[6]
        let checksum = bytes[7]
        let bodyStart = packet.index(packet.startIndex, offsetBy: 8)
        let body = packet.subdata(in: bodyStart..<packet.endIndex)
        return ParsedOuter(
            totalLen: totalLen, sessionId: sessionId, seq: seq,
            pktType: pktType, checksum: checksum, body: body
        )
    }

    /// Generates a fresh random session id, matching Python's
    /// `random.randint(1, 0xFFFE)`. Intended to be called exactly once
    /// per connection (by the caller that owns the session), never
    /// per-packet -- see `buildOuter`'s doc comment above.
    public static func randomSessionId() -> UInt16 {
        UInt16.random(in: 1...0xFFFE)
    }

    // MARK: - §3.3 handshake / ack / telemetry builders

    /// Builds the full 48-byte handshake packet: `buildOuter(0x00, seq,
    /// handshakeBody, sessionId)`. Matches the Python prototype's
    /// `build_outer(0x00, seq_counter, HANDSHAKE_BODY)` call sites (both
    /// the initial send and the 2s-silence resend -- the resend timer
    /// itself is a later task).
    public static func buildHandshake(seq: UInt16, sessionId: UInt16) -> Data {
        buildOuter(pktType: packetTypeHandshake, seq: seq, body: handshakeBody, sessionId: sessionId)
    }

    /// Builds a full ack packet: an 8-byte outer header (type 0x04)
    /// wrapping the 22-byte ack body (4-byte start/end sequence range +
    /// the 18-byte `ackTail` constant). Matches Python `stream.build_ack`.
    public static func buildAck(startSeq: UInt16, endSeq: UInt16, seq: UInt16, sessionId: UInt16) -> Data {
        var body = Data()
        body.append(UInt8(startSeq & 0xFF))
        body.append(UInt8((startSeq >> 8) & 0xFF))
        body.append(UInt8(endSeq & 0xFF))
        body.append(UInt8((endSeq >> 8) & 0xFF))
        body.append(ackTail)
        return buildOuter(pktType: packetTypeAck, seq: seq, body: body, sessionId: sessionId)
    }

    /// Builds a type-0x01 telemetry packet wrapping a pre-built DUML
    /// frame: 24 zero bytes (transmission state) + u16 LE DUML length +
    /// the DUML frame itself. Matches Python `stream.build_telemetry_with_duml`.
    public static func buildTelemetryWithDUML(dumlFrame: Data, seq: UInt16, sessionId: UInt16) -> Data {
        var body = Data(repeating: 0, count: 24)
        let len = UInt16(dumlFrame.count)
        body.append(UInt8(len & 0xFF))
        body.append(UInt8((len >> 8) & 0xFF))
        body.append(dumlFrame)
        return buildOuter(pktType: packetTypeTelemetry, seq: seq, body: body, sessionId: sessionId)
    }

    /// Builds the best-effort I-frame-request telemetry packet: the DUML
    /// 02:B3 frame (fixed sender/receiver/seq/cmd_type/cmd_set/cmd_id
    /// above, empty payload) wrapped via `buildTelemetryWithDUML`. Matches
    /// Python `stream.send_request_iframe`'s DUML-building + telemetry-
    /// wrapping steps (the USB write itself is a later task's job).
    public static func requestIFrameTelemetry(
        seq: UInt16, sessionId: UInt16, receiver: UInt8 = iframeRequestReceiver
    ) -> Data {
        let frame = DUML.build(
            sender: iframeRequestSender, receiver: receiver, seq: iframeRequestSeq,
            cmdType: iframeRequestCmdType, cmdSet: iframeRequestCmdSet, cmdId: iframeRequestCmdId,
            payload: Data()
        )
        return buildTelemetryWithDUML(dumlFrame: frame, seq: seq, sessionId: sessionId)
    }

    // MARK: - §8.6 diagnosability: unknown packet types

    /// Injectable sink for "unknown/unrecognized packet type" diagnostics
    /// (design §8.6: log, don't silently drop). Defaults to a
    /// `#if DEBUG`-gated `print` to stderr.
    ///
    /// Why not `os_log`/`OSLog`: this package's whole point (see
    /// `GogglesProtocol.swift`'s header comment) is staying pure
    /// Foundation so it can be unit-tested and reused without pulling in
    /// Apple-framework-specific behavior. `OSLog` is available on Darwin
    /// without extra linking, but it's still a distinct system framework
    /// import beyond Foundation, and — being a unified-logging sink —
    /// isn't straightforwardly assertable from an XCTest/swift-testing
    /// vector the way a plain closure is. An injectable closure keeps the
    /// zero-dependency constraint intact, lets a future host app (which
    /// *can* import OSLog) redirect these into `os_log` itself by
    /// assigning this property, and is trivially testable by swapping in
    /// a capturing closure. This is a deliberate choice, not an oversight.
    public static var unknownPacketTypeHandler: (_ rawType: UInt8, _ context: String) -> Void = { rawType, context in
        #if DEBUG
        FileHandle.standardError.write(
            Data("[GogglesProtocol] unknown packet type 0x\(String(format: "%02X", rawType))\(context.isEmpty ? "" : " (\(context))")\n".utf8)
        )
        #endif
    }

    /// Recognized outer packet types (§3.3). Used together with
    /// `logUnknownPacketType` by a future receive path (task 1.3+) to
    /// classify inbound packets and flag anything not on this list rather
    /// than dropping it silently.
    public static let knownPacketTypes: Set<UInt8> = [
        packetTypeHandshake, packetTypeTelemetry, packetTypeVideo, packetTypeAck, packetTypeAckAlt,
    ]

    /// Reports an unrecognized packet type via `unknownPacketTypeHandler`
    /// if `rawType` isn't one of `knownPacketTypes`. Returns whether it
    /// was known, so a caller can early-return on `false` after logging.
    @discardableResult
    public static func logUnknownPacketType(_ rawType: UInt8, context: String = "") -> Bool {
        if knownPacketTypes.contains(rawType) {
            return true
        }
        unknownPacketTypeHandler(rawType, context)
        return false
    }

    // MARK: - §8.6 diagnosability: malformed DUML frames

    /// Injectable sink for "`DUML.parseStream` found something that isn't
    /// a valid frame and is skipping forward" diagnostics (design §8.6:
    /// log, don't silently drop). Used by `DUML.parseStream`'s
    /// bad-magic / implausible-length / CRC-8 / CRC-16 skip branches.
    ///
    /// A sibling of `unknownPacketTypeHandler` above rather than a reuse of
    /// it: that handler's `rawType` parameter and the `knownPacketTypes`
    /// gate in `logUnknownPacketType` are specifically about *outer-header*
    /// packet-type bytes (a future receive loop's concern). Reusing them
    /// here would let a DUML payload byte that happens to collide with a
    /// known outer packet-type value (0x00/0x01/0x02/0x04/0x06) get
    /// silently swallowed by that classification check -- exactly the
    /// silent-drop behavior §8.6 exists to prevent. This hook has the same
    /// shape (closure, `#if DEBUG`-gated stderr default, zero extra
    /// dependencies beyond Foundation) for consistency and testability,
    /// but no gating: every call site already knows it found something
    /// malformed, there's nothing to classify.
    public static var malformedFrameHandler: (_ reason: String, _ context: String) -> Void = { reason, context in
        #if DEBUG
        FileHandle.standardError.write(
            Data("[GogglesProtocol] malformed DUML frame skipped: \(reason)\(context.isEmpty ? "" : " (\(context))")\n".utf8)
        )
        #endif
    }

    /// Reports a position in the stream that `DUML.parseStream` determined
    /// is not (the start of) a valid frame, immediately before it advances
    /// past it, via `malformedFrameHandler`.
    public static func logMalformedFrame(reason: String, context: String = "") {
        malformedFrameHandler(reason, context)
    }
}
