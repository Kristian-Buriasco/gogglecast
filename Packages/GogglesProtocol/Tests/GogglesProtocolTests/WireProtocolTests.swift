// Golden-vector parity tests for Task 1.2's wire-protocol layer
// (WireProtocol.buildOuter/buildHandshake/buildAck and the DUML codec).
// Verifies the Swift port produces byte-identical (or value-identical)
// output to the Python prototype for every relevant vector in
// `Fixtures/golden.json`.

import Testing
import Foundation
@testable import GogglesProtocol

// MARK: - buildOuter (per packet type)

@Test func buildOuterHandshakeType() throws {
    let v = try GoldenVectors.vector("build_outer_pkt_type_handshake")
    let result = WireProtocol.buildOuter(
        pktType: UInt8(v.intInput("pktType")), seq: UInt16(v.intInput("seq")),
        body: v.hexInput("body"), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result == v.outputData)
}

@Test func buildOuterTelemetryType() throws {
    let v = try GoldenVectors.vector("build_outer_pkt_type_telemetry")
    let result = WireProtocol.buildOuter(
        pktType: UInt8(v.intInput("pktType")), seq: UInt16(v.intInput("seq")),
        body: v.hexInput("body"), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result == v.outputData)
}

@Test func buildOuterVideoType() throws {
    let v = try GoldenVectors.vector("build_outer_pkt_type_video")
    let result = WireProtocol.buildOuter(
        pktType: UInt8(v.intInput("pktType")), seq: UInt16(v.intInput("seq")),
        body: v.hexInput("body"), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result == v.outputData)
}

@Test func buildOuterAckType() throws {
    let v = try GoldenVectors.vector("build_outer_pkt_type_ack")
    let result = WireProtocol.buildOuter(
        pktType: UInt8(v.intInput("pktType")), seq: UInt16(v.intInput("seq")),
        body: v.hexInput("body"), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result == v.outputData)
}

// MARK: - handshake / ack

@Test func handshake48Bytes() throws {
    let v = try GoldenVectors.vector("handshake_48_bytes")
    let bodyFromVector = v.hexInput("handshakeBody")
    #expect(bodyFromVector == WireProtocol.handshakeBody)
    let result = WireProtocol.buildHandshake(
        seq: UInt16(v.intInput("seq")), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result.count == 48)
    #expect(result == v.outputData)
}

@Test func ack22ByteBody() throws {
    let v = try GoldenVectors.vector("ack_22_byte_body")
    let result = WireProtocol.buildAck(
        startSeq: UInt16(v.intInput("startSeq")), endSeq: UInt16(v.intInput("endSeq")),
        seq: UInt16(v.intInput("seq")), sessionId: UInt16(v.intInput("sessionId"))
    )
    #expect(result.count == 30)
    #expect(result == v.outputData)
}

// MARK: - DUML crc8 / crc16

@Test func dumlCRC8Header() throws {
    let v = try GoldenVectors.vector("duml_crc8_header")
    let result = DUML.crc8(v.hexInput("data"))
    #expect(Int(result) == v.outputInt)
}

@Test func dumlCRC16WholeFramePrefix() throws {
    let v = try GoldenVectors.vector("duml_crc16_whole_frame_prefix")
    let result = DUML.crc16(v.hexInput("data"))
    #expect(Int(result) == v.outputInt)
}

// MARK: - DUML build

@Test func dumlBuild02B3IFrameRequest() throws {
    let v = try GoldenVectors.vector("duml_build_02_b3_iframe_request")
    let result = DUML.build(
        sender: UInt8(v.intInput("sender")), receiver: UInt8(v.intInput("receiver")),
        seq: UInt16(v.intInput("seq")), cmdType: UInt8(v.intInput("cmdType")),
        cmdSet: UInt8(v.intInput("cmdSet")), cmdId: UInt8(v.intInput("cmdId")),
        payload: v.hexInput("payload")
    )
    #expect(result == v.outputData)

    // Also verify WireProtocol's fixed I-frame-request constants match
    // this vector's inputs (the actual send_request_iframe call site).
    #expect(WireProtocol.iframeRequestSender == UInt8(v.intInput("sender")))
    #expect(WireProtocol.iframeRequestReceiver == UInt8(v.intInput("receiver")))
    #expect(WireProtocol.iframeRequestSeq == UInt16(v.intInput("seq")))
    #expect(WireProtocol.iframeRequestCmdType == UInt8(v.intInput("cmdType")))
    #expect(WireProtocol.iframeRequestCmdSet == UInt8(v.intInput("cmdSet")))
    #expect(WireProtocol.iframeRequestCmdId == UInt8(v.intInput("cmdId")))
}

@Test func dumlBuildWithNonEmptyPayload() throws {
    let v = try GoldenVectors.vector("duml_build_with_nonempty_payload")
    let result = DUML.build(
        sender: UInt8(v.intInput("sender")), receiver: UInt8(v.intInput("receiver")),
        seq: UInt16(v.intInput("seq")), cmdType: UInt8(v.intInput("cmdType")),
        cmdSet: UInt8(v.intInput("cmdSet")), cmdId: UInt8(v.intInput("cmdId")),
        payload: v.hexInput("payload")
    )
    #expect(result == v.outputData)
}

// MARK: - DUML parseStream

@Test func dumlParseStreamSyntheticIF4() throws {
    let v = try GoldenVectors.vector("duml_parse_stream_synthetic_if4")
    let (packets, tail) = DUML.parseStream(v.hexInput("buf"))
    let expected = v.outputObject!
    let expectedPackets = expected["packets"] as! [[String: Any]]
    let expectedTail = GoldenVectors.Vector.dataFromHex(expected["tailHex"] as! String)

    #expect(packets.count == expectedPackets.count)
    for (p, e) in zip(packets, expectedPackets) {
        #expect(Int(p.version) == (e["version"] as? NSNumber)?.intValue)
        #expect(Int(p.sender) == (e["sender"] as? NSNumber)?.intValue)
        #expect(Int(p.receiver) == (e["receiver"] as? NSNumber)?.intValue)
        #expect(Int(p.seq) == (e["seq"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdType) == (e["cmdType"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdSet) == (e["cmdSet"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdId) == (e["cmdId"] as? NSNumber)?.intValue)
        #expect(p.payload == GoldenVectors.Vector.dataFromHex(e["payloadHex"] as! String))
        #expect(p.raw == GoldenVectors.Vector.dataFromHex(e["rawHex"] as! String))
    }
    #expect(tail == expectedTail)
}

@Test func dumlParseStreamSyntheticCleanTwoFrames() throws {
    let v = try GoldenVectors.vector("duml_parse_stream_synthetic_clean_two_frames")
    let (packets, tail) = DUML.parseStream(v.hexInput("buf"))
    let expected = v.outputObject!
    let expectedPackets = expected["packets"] as! [[String: Any]]
    let expectedTail = GoldenVectors.Vector.dataFromHex(expected["tailHex"] as! String)

    #expect(packets.count == expectedPackets.count)
    for (p, e) in zip(packets, expectedPackets) {
        #expect(Int(p.version) == (e["version"] as? NSNumber)?.intValue)
        #expect(Int(p.sender) == (e["sender"] as? NSNumber)?.intValue)
        #expect(Int(p.receiver) == (e["receiver"] as? NSNumber)?.intValue)
        #expect(Int(p.seq) == (e["seq"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdType) == (e["cmdType"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdSet) == (e["cmdSet"] as? NSNumber)?.intValue)
        #expect(Int(p.cmdId) == (e["cmdId"] as? NSNumber)?.intValue)
        #expect(p.payload == GoldenVectors.Vector.dataFromHex(e["payloadHex"] as! String))
        #expect(p.raw == GoldenVectors.Vector.dataFromHex(e["rawHex"] as! String))
    }
    #expect(tail == expectedTail)
    #expect(tail.isEmpty)
}

// MARK: - unknown packet type logging (not covered by golden.json --
// this is Swift-side diagnosability behavior per design §8.6)

@Test func unknownPacketTypeIsLoggedNotSilentlyDropped() {
    var logged: (UInt8, String)?
    let previous = WireProtocol.unknownPacketTypeHandler
    defer { WireProtocol.unknownPacketTypeHandler = previous }
    WireProtocol.unknownPacketTypeHandler = { rawType, context in
        logged = (rawType, context)
    }

    let knownResult = WireProtocol.logUnknownPacketType(WireProtocol.packetTypeHandshake)
    #expect(knownResult == true)
    #expect(logged == nil)

    let unknownResult = WireProtocol.logUnknownPacketType(0xEE, context: "test")
    #expect(unknownResult == false)
    #expect(logged?.0 == 0xEE)
    #expect(logged?.1 == "test")
}

// MARK: - malformed DUML frames are logged, not silently dropped, by
// DUML.parseStream's skip branches (design §8.6)

// These four tests observe `DUML.parseStream`'s malformed-frame diagnostics
// via the `onMalformedFrame` parameter added specifically so tests don't
// need to swap the shared `WireProtocol.malformedFrameHandler` global in
// and out. Swift Testing parallelizes tests by default, and a save/mutate/
// defer-restore dance around one shared static var is not safe under that:
// two of these tests can be mid-flight at once, so one test's mutation of
// the global is visible to (or gets overwritten by) another's before either
// restores it, producing nondeterministic cross-test contamination. Passing
// a closure straight into `parseStream` keeps each test's observation local
// to its own call stack, with no shared mutable state at all.

@Test func parseStreamBadMagicIsLoggedNotSilentlyDropped() {
    var reasons: [String] = []

    // A single stray byte that is not the DUML magic (0x55) and never
    // resolves into a valid frame.
    let (packets, tail) = DUML.parseStream(Data([0xAA])) { reason, _ in reasons.append(reason) }
    #expect(packets.isEmpty)
    #expect(tail.isEmpty)
    #expect(reasons.count == 1)
    #expect(reasons[0].contains("bad magic"))
}

@Test func parseStreamCRC8FailureIsLoggedNotSilentlyDropped() {
    var reasons: [String] = []

    // A validly-built frame with its CRC-8 header byte corrupted --
    // magic and length are intact, so parseStream reaches the CRC-8
    // check specifically.
    var frame = [UInt8](DUML.build(
        sender: 0x2A, receiver: 0xBC, seq: 0x9000, cmdType: 0x40, cmdSet: 0x02, cmdId: 0xB3
    ))
    frame[3] = frame[3] &+ 1 // flip the CRC-8 byte so it no longer matches

    let (packets, tail) = DUML.parseStream(Data(frame)) { reason, _ in reasons.append(reason) }
    #expect(packets.isEmpty)
    #expect(tail.isEmpty)
    #expect(reasons.contains { $0.contains("CRC-8") })
}

@Test func parseStreamCRC16FailureIsLoggedNotSilentlyDropped() {
    var reasons: [String] = []

    // A validly-built frame with its trailing CRC-16 byte corrupted --
    // the CRC-8 header check still passes, so parseStream reaches the
    // CRC-16 check specifically.
    var frame = [UInt8](DUML.build(
        sender: 0x2A, receiver: 0xBC, seq: 0x9000, cmdType: 0x40, cmdSet: 0x02, cmdId: 0xB3
    ))
    frame[frame.count - 1] = frame[frame.count - 1] &+ 1 // flip the last CRC-16 byte

    let (packets, tail) = DUML.parseStream(Data(frame)) { reason, _ in reasons.append(reason) }
    #expect(packets.isEmpty)
    #expect(tail.isEmpty)
    #expect(reasons.contains { $0.contains("CRC-16") })
}

@Test func parseStreamImplausibleLengthIsLoggedNotSilentlyDropped() {
    var reasons: [String] = []

    // Magic byte followed by a length field claiming a frame shorter
    // than DUML.minLen (13). Length is encoded little-endian across
    // bytes[1..2] with a zero version nibble, so a raw value of 5 here
    // decodes to length 5, well under minLen. A 4th byte is included
    // so parseStream has enough bytes to read the header fields at all
    // (fewer than 4 bytes hits the "header not all here yet" break,
    // not the length check).
    let buf = Data([DUML.magic, 0x05, 0x00, 0x00])
    let (packets, tail) = DUML.parseStream(buf) { reason, _ in reasons.append(reason) }
    #expect(packets.isEmpty)
    #expect(tail.isEmpty)
    #expect(reasons.contains { $0.contains("implausible") })
}
