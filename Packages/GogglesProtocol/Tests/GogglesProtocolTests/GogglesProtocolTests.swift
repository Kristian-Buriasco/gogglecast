// Golden-vector parity tests for Task 1.1's framing primitives (RawNet +
// RNDIS message framing). Verifies the Swift port produces byte-identical
// output to the Python prototype for every relevant vector in
// `Fixtures/golden.json`.
//
// Uses Swift Testing (`import Testing`), not XCTest: this environment only
// has the Xcode Command Line Tools installed (no full Xcode.app), and the
// XCTest module is unavailable there.

import Testing
import Foundation
@testable import GogglesProtocol

// MARK: - checksum16

@Test func checksum16EvenLength() throws {
    let v = try GoldenVectors.vector("checksum16_even_length")
    let result = RawNet.checksum16(v.hexInput("data"))
    #expect(Int(result) == v.outputInt)
}

@Test func checksum16OddLengthPadding() throws {
    let v = try GoldenVectors.vector("checksum16_odd_length_padding")
    let result = RawNet.checksum16(v.hexInput("data"))
    #expect(Int(result) == v.outputInt)
}

@Test func checksum16RealIPv4Header() throws {
    let v = try GoldenVectors.vector("checksum16_real_ipv4_header")
    let result = RawNet.checksum16(v.hexInput("data"))
    #expect(Int(result) == v.outputInt)
}

// MARK: - buildUDP

@Test func buildUDPBasic() throws {
    let v = try GoldenVectors.vector("build_udp_basic")
    let result = RawNet.buildUDP(
        srcMac: v.hexInput("srcMac"), dstMac: v.hexInput("dstMac"),
        srcIp: v.stringInput("srcIp"), dstIp: v.stringInput("dstIp"),
        srcPort: UInt16(v.intInput("srcPort")), dstPort: UInt16(v.intInput("dstPort")),
        payload: v.hexInput("payload")
    )
    #expect(result == v.outputData)
}

@Test func buildUDPEmptyPayload() throws {
    let v = try GoldenVectors.vector("build_udp_empty_payload")
    let result = RawNet.buildUDP(
        srcMac: v.hexInput("srcMac"), dstMac: v.hexInput("dstMac"),
        srcIp: v.stringInput("srcIp"), dstIp: v.stringInput("dstIp"),
        srcPort: UInt16(v.intInput("srcPort")), dstPort: UInt16(v.intInput("dstPort")),
        payload: v.hexInput("payload")
    )
    #expect(result == v.outputData)
}

// MARK: - buildARPRequest / buildARPReply

@Test func buildARPRequestBasic() throws {
    let v = try GoldenVectors.vector("build_arp_request_basic")
    let result = RawNet.buildARPRequest(
        srcMac: v.hexInput("srcMac"), srcIp: v.stringInput("srcIp"), targetIp: v.stringInput("targetIp")
    )
    #expect(result == v.outputData)
}

@Test func buildARPReplyBasic() throws {
    let v = try GoldenVectors.vector("build_arp_reply_basic")
    let result = RawNet.buildARPReply(
        srcMac: v.hexInput("srcMac"), srcIp: v.stringInput("srcIp"),
        dstMac: v.hexInput("dstMac"), dstIp: v.stringInput("dstIp")
    )
    #expect(result == v.outputData)
}

// MARK: - parseUDP

@Test func parseUDPRoundTrip() throws {
    let v = try GoldenVectors.vector("parse_udp_round_trip")
    let result = RawNet.parseUDP(v.hexInput("frame"))
    let expected = v.outputObject!
    #expect(result?.srcIp == expected["srcIp"] as? String)
    #expect(result?.dstIp == expected["dstIp"] as? String)
    #expect(Int(result?.srcPort ?? 0) == (expected["srcPort"] as? NSNumber)?.intValue)
    #expect(Int(result?.dstPort ?? 0) == (expected["dstPort"] as? NSNumber)?.intValue)
    #expect(result?.payload == GoldenVectors.Vector.dataFromHex(expected["payloadHex"] as! String))
}

@Test func parseUDPTooShortReturnsNil() throws {
    let v = try GoldenVectors.vector("parse_udp_too_short_returns_none")
    let result = RawNet.parseUDP(v.hexInput("frame"))
    #expect(result == nil)
    #expect(v.outputIsNull)
}

@Test func parseUDPWrongEthertypeReturnsNil() throws {
    let v = try GoldenVectors.vector("parse_udp_wrong_ethertype_returns_none")
    let result = RawNet.parseUDP(v.hexInput("frame"))
    #expect(result == nil)
    #expect(v.outputIsNull)
}

// MARK: - parseARP

@Test func parseARPRoundTripRequest() throws {
    let v = try GoldenVectors.vector("parse_arp_round_trip_request")
    let result = RawNet.parseARP(v.hexInput("frame"))
    let expected = v.outputObject!
    #expect(Int(result?.op ?? 0) == (expected["op"] as? NSNumber)?.intValue)
    #expect(result?.senderMac == GoldenVectors.Vector.dataFromHex(expected["senderMac"] as! String))
    #expect(result?.senderIp == expected["senderIp"] as? String)
    #expect(result?.targetMac == GoldenVectors.Vector.dataFromHex(expected["targetMac"] as! String))
    #expect(result?.targetIp == expected["targetIp"] as? String)
}

@Test func parseARPRoundTripReply() throws {
    let v = try GoldenVectors.vector("parse_arp_round_trip_reply")
    let result = RawNet.parseARP(v.hexInput("frame"))
    let expected = v.outputObject!
    #expect(Int(result?.op ?? 0) == (expected["op"] as? NSNumber)?.intValue)
    #expect(result?.senderMac == GoldenVectors.Vector.dataFromHex(expected["senderMac"] as! String))
    #expect(result?.senderIp == expected["senderIp"] as? String)
    #expect(result?.targetMac == GoldenVectors.Vector.dataFromHex(expected["targetMac"] as! String))
    #expect(result?.targetIp == expected["targetIp"] as? String)
}

@Test func parseARPTooShortReturnsNil() throws {
    let v = try GoldenVectors.vector("parse_arp_too_short_returns_none")
    let result = RawNet.parseARP(v.hexInput("frame"))
    #expect(result == nil)
    #expect(v.outputIsNull)
}

// MARK: - wrapPacketMsg / unwrapPacketMsg

@Test func wrapPacketMsgSingle() throws {
    let v = try GoldenVectors.vector("wrap_packet_msg_single")
    let result = RNDIS.wrapPacketMsg(v.hexInput("frame"))
    #expect(result == v.outputData)
}

@Test func unwrapPacketMsgSingle() throws {
    let v = try GoldenVectors.vector("unwrap_packet_msg_single")
    let result = RNDIS.unwrapPacketMsg(v.hexInput("buf"))
    let expected = (v.outputArray ?? []).map { GoldenVectors.Vector.dataFromHex($0 as! String) }
    #expect(result == expected)
}

@Test func unwrapPacketMsgMultiMessageBuffer() throws {
    let v = try GoldenVectors.vector("unwrap_packet_msg_multi_message_buffer")
    let result = RNDIS.unwrapPacketMsg(v.hexInput("buf"))
    let expected = (v.outputArray ?? []).map { GoldenVectors.Vector.dataFromHex($0 as! String) }
    #expect(result == expected)
}

// MARK: - RNDIS control-message builders
//
// golden.json has no vectors for initializeMsg/setMsg/queryMsg (the Python
// prototype's rndis_initialize/rndis_set/rndis_query all perform a live USB
// round trip and aren't pure functions gen_golden.py could call safely
// offline). These builders are ported directly from the message-building
// halves of those functions per design.md §3.1 and are exercised here with
// direct layout assertions instead, matching the byte layouts spelled out
// in the design doc and rndis.py.

@Test func initializeMsgLayout() {
    let msg = RNDIS.initializeMsg(requestId: 1)
    #expect(msg.count == 24)
    let bytes = [UInt8](msg)
    #expect(bytes[0...3] == [0x02, 0x00, 0x00, 0x00]) // type
    #expect(bytes[4...7] == [0x18, 0x00, 0x00, 0x00]) // length = 24
    #expect(bytes[8...11] == [0x01, 0x00, 0x00, 0x00]) // requestId = 1
    #expect(bytes[12...15] == [0x01, 0x00, 0x00, 0x00]) // majorVersion = 1
    #expect(bytes[16...19] == [0x00, 0x00, 0x00, 0x00]) // minorVersion = 0
    #expect(bytes[20...23] == [0x00, 0x40, 0x00, 0x00]) // maxTransferSize = 0x4000
}

@Test func setMsgLayout() {
    let value: [UInt8] = [0x35, 0x00, 0x00, 0x00] // packet filter value from design §3.1
    let msg = RNDIS.setMsg(oid: RNDIS.OID_GEN_CURRENT_PACKET_FILTER, value: Data(value), requestId: 2)
    #expect(msg.count == 28 + value.count)
    let bytes = [UInt8](msg)
    #expect(bytes[0...3] == [0x05, 0x00, 0x00, 0x00]) // type
    #expect(bytes[4...7] == [0x20, 0x00, 0x00, 0x00]) // msgLen = 28 + 4 = 32
    #expect(bytes[8...11] == [0x02, 0x00, 0x00, 0x00]) // requestId = 2
    #expect(bytes[12...15] == [0x0E, 0x01, 0x01, 0x00]) // oid = 0x0001010E LE
    #expect(bytes[16...19] == [0x04, 0x00, 0x00, 0x00]) // infoLen = 4
    #expect(bytes[20...23] == [0x14, 0x00, 0x00, 0x00]) // infoBufferOffset = 20
    #expect(bytes[24...27] == [0x00, 0x00, 0x00, 0x00]) // deviceVcHandle = 0
    #expect(Array(bytes[28...31]) == value)
}

@Test func queryMsgLayout() {
    let msg = RNDIS.queryMsg(oid: RNDIS.OID_802_3_CURRENT_ADDRESS, requestId: 3)
    #expect(msg.count == 28)
    let bytes = [UInt8](msg)
    #expect(bytes[0...3] == [0x04, 0x00, 0x00, 0x00]) // type
    #expect(bytes[4...7] == [0x1C, 0x00, 0x00, 0x00]) // msgLen = 28
    #expect(bytes[8...11] == [0x03, 0x00, 0x00, 0x00]) // requestId = 3
    #expect(bytes[12...15] == [0x02, 0x01, 0x01, 0x01]) // oid = 0x01010102 LE
    #expect(bytes[16...19] == [0x00, 0x00, 0x00, 0x00]) // infoLen = 0
    #expect(bytes[20...23] == [0x14, 0x00, 0x00, 0x00]) // infoBufferOffset = 20
    #expect(bytes[24...27] == [0x00, 0x00, 0x00, 0x00]) // deviceVcHandle = 0
}
