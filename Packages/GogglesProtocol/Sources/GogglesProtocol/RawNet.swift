import Foundation

/// Minimal hand-rolled Ethernet/IPv4/UDP/ARP frame build+parse — we bypass
/// the OS network stack entirely and talk to the RNDIS link raw.
///
/// This is a byte-exact Swift port of the Python prototype's `rawnet.py`.
/// Pure Foundation only — no networking frameworks.
public enum RawNet {

    // MARK: - checksum16

    /// One's-complement 16-bit checksum (RFC 1071), e.g. for the IPv4
    /// header checksum field. Matches Python `rawnet.checksum16`.
    public static func checksum16(_ data: Data) -> UInt16 {
        var bytes = [UInt8](data)
        if bytes.count % 2 != 0 {
            bytes.append(0)
        }
        var total: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let word = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            total += UInt32(word)
            i += 2
        }
        while (total >> 16) != 0 {
            total = (total & 0xFFFF) + (total >> 16)
        }
        return UInt16(~total & 0xFFFF)
    }

    // MARK: - IPv4 helpers

    /// Parses a dotted-decimal IPv4 address string ("a.b.c.d") into 4 bytes.
    /// Traps (fatalError) on malformed input, mirroring the Python
    /// prototype's unchecked `int(x) for x in s.split(".")` -- callers in
    /// this codebase always pass well-formed literals or values already
    /// validated elsewhere.
    static func ipBytes(_ s: String) -> Data {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        precondition(parts.count == 4, "malformed IPv4 address: \(s)")
        var out = Data()
        out.reserveCapacity(4)
        for p in parts {
            guard let v = UInt8(p) else {
                preconditionFailure("malformed IPv4 address octet: \(s)")
            }
            out.append(v)
        }
        return out
    }

    static func ipString(_ bytes: Data) -> String {
        bytes.map { String($0) }.joined(separator: ".")
    }

    // MARK: - build_udp

    /// Builds a full Ethernet+IPv4+UDP frame. Matches Python `rawnet.build_udp`.
    public static func buildUDP(
        srcMac: Data, dstMac: Data,
        srcIp: String, dstIp: String,
        srcPort: UInt16, dstPort: UInt16,
        payload: Data
    ) -> Data {
        let udpLen = 8 + payload.count
        var udpHeader = Data()
        udpHeader.appendBE(srcPort)
        udpHeader.appendBE(dstPort)
        udpHeader.appendBE(UInt16(udpLen))
        udpHeader.appendBE(UInt16(0))
        let udpPacket = udpHeader + payload

        let ipId: UInt16 = 0x1234
        let totalLen = UInt16(20 + udpLen)
        let srcIpBytes = ipBytes(srcIp)
        let dstIpBytes = ipBytes(dstIp)

        func ipHeader(checksum: UInt16) -> Data {
            var h = Data()
            h.append(0x45)
            h.append(0x00)
            h.appendBE(totalLen)
            h.appendBE(ipId)
            h.appendBE(UInt16(0x4000))
            h.append(64)
            h.append(17)
            h.appendBE(checksum)
            h.append(srcIpBytes)
            h.append(dstIpBytes)
            return h
        }

        let ipHeaderNoChecksum = ipHeader(checksum: 0)
        let cksum = checksum16(ipHeaderNoChecksum)
        let ipHeaderFinal = ipHeader(checksum: cksum)

        var ethHeader = Data()
        ethHeader.append(dstMac)
        ethHeader.append(srcMac)
        ethHeader.appendBE(UInt16(0x0800))

        return ethHeader + ipHeaderFinal + udpPacket
    }

    // MARK: - build_arp_request / build_arp_reply

    /// Builds a broadcast ARP "who-has" request. Matches
    /// Python `rawnet.build_arp_request`.
    public static func buildARPRequest(srcMac: Data, srcIp: String, targetIp: String) -> Data {
        var arp = Data()
        arp.appendBE(UInt16(1))       // hardware type: Ethernet
        arp.appendBE(UInt16(0x0800))  // protocol type: IPv4
        arp.append(6)                 // hardware address length
        arp.append(4)                 // protocol address length
        arp.appendBE(UInt16(1))       // opcode: request
        arp.append(srcMac)
        arp.append(ipBytes(srcIp))
        arp.append(Data(repeating: 0, count: 6))
        arp.append(ipBytes(targetIp))

        var ethHeader = Data()
        ethHeader.append(Data(repeating: 0xFF, count: 6))
        ethHeader.append(srcMac)
        ethHeader.appendBE(UInt16(0x0806))

        return ethHeader + arp
    }

    /// Builds a unicast ARP "is-at" reply. Matches
    /// Python `rawnet.build_arp_reply`.
    public static func buildARPReply(srcMac: Data, srcIp: String, dstMac: Data, dstIp: String) -> Data {
        var arp = Data()
        arp.appendBE(UInt16(1))       // hardware type: Ethernet
        arp.appendBE(UInt16(0x0800))  // protocol type: IPv4
        arp.append(6)
        arp.append(4)
        arp.appendBE(UInt16(2))       // opcode: reply
        arp.append(srcMac)
        arp.append(ipBytes(srcIp))
        arp.append(dstMac)
        arp.append(ipBytes(dstIp))

        var ethHeader = Data()
        ethHeader.append(dstMac)
        ethHeader.append(srcMac)
        ethHeader.appendBE(UInt16(0x0806))

        return ethHeader + arp
    }

    // MARK: - parse_arp / parse_udp

    public struct ParsedARP: Equatable {
        public let op: UInt16
        public let senderMac: Data
        public let senderIp: String
        public let targetMac: Data
        public let targetIp: String
    }

    /// Parses an ARP-over-Ethernet frame. Returns `nil` on malformed input
    /// (too short, or wrong EtherType) -- matches Python `rawnet.parse_arp`
    /// returning `None`.
    public static func parseARP(_ frame: Data) -> ParsedARP? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 42 else { return nil }
        guard bytes[12] == 0x08, bytes[13] == 0x06 else { return nil }
        let op = (UInt16(bytes[20]) << 8) | UInt16(bytes[21])
        let senderMac = Data(bytes[22..<28])
        let senderIp = ipString(Data(bytes[28..<32]))
        let targetMac = Data(bytes[32..<38])
        let targetIp = ipString(Data(bytes[38..<42]))
        return ParsedARP(op: op, senderMac: senderMac, senderIp: senderIp,
                          targetMac: targetMac, targetIp: targetIp)
    }

    public struct ParsedUDP: Equatable {
        public let srcIp: String
        public let dstIp: String
        public let srcPort: UInt16
        public let dstPort: UInt16
        public let payload: Data
    }

    /// Parses an Ethernet+IPv4+UDP frame. Returns `nil` on malformed input
    /// (too short, wrong EtherType, or non-UDP protocol) -- matches Python
    /// `rawnet.parse_udp` returning `None`.
    public static func parseUDP(_ frame: Data) -> ParsedUDP? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 42 else { return nil }
        guard bytes[12] == 0x08, bytes[13] == 0x00 else { return nil }
        let ihl = Int(bytes[14] & 0x0F) * 4
        let proto = bytes[23]
        guard proto == 17 else { return nil }
        let srcIp = ipString(Data(bytes[26..<30]))
        let dstIp = ipString(Data(bytes[30..<34]))
        let udpOff = 14 + ihl
        guard bytes.count >= udpOff + 8 else { return nil }
        let srcPort = (UInt16(bytes[udpOff]) << 8) | UInt16(bytes[udpOff + 1])
        let dstPort = (UInt16(bytes[udpOff + 2]) << 8) | UInt16(bytes[udpOff + 3])
        let udpLen = (UInt16(bytes[udpOff + 4]) << 8) | UInt16(bytes[udpOff + 5])
        let payloadStart = udpOff + 8
        let payloadEnd = udpOff + Int(udpLen)
        let clampedEnd = min(max(payloadEnd, payloadStart), bytes.count)
        let payload = Data(bytes[payloadStart..<clampedEnd])
        return ParsedUDP(srcIp: srcIp, dstIp: dstIp, srcPort: srcPort, dstPort: dstPort, payload: payload)
    }
}

// MARK: - Data big-endian append helpers

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
