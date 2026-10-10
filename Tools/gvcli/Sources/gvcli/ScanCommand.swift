import Foundation
import GogglesProtocol
import GogglesUSB

/// `gvcli scan`: research aid for goggles that do not speak the Goggles 3 video protocol. Over the RNDIS
/// link it sends TCP SYN and empty UDP probes to the goggles' IP and reports which ports answer.
/// TCP: SYN-ACK = open, RST = closed. UDP: ICMP port-unreachable = closed, a UDP reply = open, silence = open|filtered.
private final class ScanResults: @unchecked Sendable {
    private let lock = NSLock()
    var tcpOpen = Set<Int>(), tcpClosed = Set<Int>(), udpClosed = Set<Int>(), udpReplies: [Int: Data] = [:]
    var other = 0
    func record(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
    func snapshot<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private func be16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }

private func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").compactMap { UInt8($0) } }

private func tcpSYN(srcMac: Data, dstMac: Data, srcIp: String, dstIp: String, srcPort: Int, dstPort: Int, seq: UInt32) -> Data {
    var tcp = Data()
    func put16(_ v: Int) { tcp.append(UInt8(v >> 8 & 0xff)); tcp.append(UInt8(v & 0xff)) }
    put16(srcPort); put16(dstPort)
    for shift in [24, 16, 8, 0] { tcp.append(UInt8(seq >> UInt32(shift) & 0xff)) }
    tcp.append(contentsOf: [0, 0, 0, 0])
    tcp.append(0x50); tcp.append(0x02)               // data offset 5, SYN
    put16(8192); put16(0); put16(0)                  // window, checksum placeholder, urgent
    var pseudo = Data(ipv4(srcIp) + ipv4(dstIp) + [0, 6, 0, UInt8(tcp.count)])
    pseudo.append(tcp)
    let ck = RawNet.checksum16(pseudo)
    tcp[16] = UInt8(ck >> 8); tcp[17] = UInt8(ck & 0xff)
    func ip(_ checksum: UInt16) -> Data {
        var h = Data([0x45, 0, 0, UInt8((20 + tcp.count) >> 8), UInt8((20 + tcp.count) & 0xff), 0x12, 0x34, 0x40, 0, 0x40, 6])
        h.append(UInt8(checksum >> 8)); h.append(UInt8(checksum & 0xff))
        h.append(contentsOf: ipv4(srcIp)); h.append(contentsOf: ipv4(dstIp))
        return h
    }
    let header = ip(RawNet.checksum16(ip(0)))
    return dstMac + srcMac + Data([0x08, 0x00]) + header + tcp
}

func runScanCommand(args: [String]) async throws {
    let seconds = Double(args.first ?? "") ?? 25
    let ip = ARPResolver.gogglesIp
    let transport = try RNDISTransport()
    let results = ScanResults()
    transport.rawInboundHandler = { frame in
        let b = [UInt8](frame)
        guard b.count >= 34, b[12] == 0x08, b[13] == 0x00 else { return }
        let ihl = Int(b[14] & 0x0f) * 4, o = 14 + ihl
        switch b[23] {
        case 6 where b.count >= o + 14:
            let sport = be16(b, o), flags = b[o + 13]
            results.record { if flags & 0x12 == 0x12 { results.tcpOpen.insert(sport) } else if flags & 0x04 != 0 { results.tcpClosed.insert(sport) } }
        case 1 where b.count >= o + 8 + 20 + 4 && b[o] == 3 && b[o + 1] == 3:
            let q = o + 8 + Int(b[o + 8] & 0x0f) * 4
            if b.count >= q + 4 { results.record { results.udpClosed.insert(be16(b, q + 2)) } }
        case 17 where b.count >= o + 8:
            let sport = be16(b, o)
            results.record { results.udpReplies[sport] = Data(b[(o + 8)...].prefix(32)) }
        default: results.record { results.other += 1 }
        }
    }
    let mac = transport.gogglesMac
    FileHandle.standardError.write(Data("[scan] goggles \(ip) mac \(mac.map { String(format: "%02x", $0) }.joined(separator: ":")), scanning ~\(Int(seconds)) s\n".utf8))

    let tcpPorts = Array(1...2048) + [3000, 4000, 5000, 5001, 5555, 6000, 7000, 7001, 7070, 8000, 8001, 8008, 8080, 8081, 8443, 8554, 8888, 9000, 9001, 9002, 9003, 9004, 9005, 9999, 10000, 12345, 20000, 40000, 50000]
    let udpPorts = Array(1...2048) + [3333, 4000, 5000, 5004, 5005, 5555, 6000, 7000, 7001, 8000, 8554, 9000, 9001, 9002, 9003, 9004, 9005, 9999, 10000, 12345, 20000, 40000, 50000]
    let deadline = Date().addingTimeInterval(seconds)
    var sent = 0
    for (i, port) in tcpPorts.enumerated() {
        if Date() > deadline { break }
        let syn = tcpSYN(srcMac: ARPResolver.hostMac, dstMac: mac, srcIp: ARPResolver.hostIp, dstIp: ip, srcPort: 40000 + i % 2000, dstPort: port, seq: UInt32(0x1000 + i))
        try? transport.sendRawEthernet(syn)
        sent += 1
        if sent % 50 == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
    for port in udpPorts {
        if Date() > deadline { break }
        let frame = RawNet.buildUDP(srcMac: ARPResolver.hostMac, dstMac: mac, srcIp: ARPResolver.hostIp, dstIp: ip,
                                    srcPort: 54321, dstPort: UInt16(port), payload: Data([0]))
        try? transport.sendRawEthernet(frame)
        sent += 1
        if sent % 20 == 0 { try? await Task.sleep(nanoseconds: 40_000_000) }
    }
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    results.snapshot {
        print("TCP open:   \(tcpOpen_sorted(results.tcpOpen))")
        print("TCP closed: \(results.tcpClosed.count) ports answered RST")
        print("UDP replies: \(results.udpReplies.keys.sorted().map { "\($0)(\(results.udpReplies[$0]!.map { String(format: "%02x", $0) }.joined()))" })")
        let tried = Set(udpPorts)
        let silent = tried.subtracting(results.udpClosed).sorted()
        print("UDP closed (ICMP unreachable): \(results.udpClosed.count) of \(tried.count)")
        print("UDP silent (open or rate-limited): \(silent.count > 60 ? "\(silent.count) ports, first 60: \(silent.prefix(60))" : "\(silent)")")
        print("other frames: \(results.other)")
    }
}

private func tcpOpen_sorted(_ s: Set<Int>) -> [Int] { s.sorted() }
