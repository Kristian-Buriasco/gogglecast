// Tests for `--dump-telemetry`'s JSON-line records and file writer.

import Testing
import Foundation
import GogglesProtocol
@testable import GogglesPipeline

@Suite struct TelemetryDumpTests {

    private func telemetryPacket(_ frames: [Data], seq: UInt16 = 0x0040) -> Data {
        var mb = Data()
        frames.forEach { mb.append($0) }
        return WireProtocol.buildTelemetryWithDUML(dumlFrame: mb, seq: seq, sessionId: 0x1234)
    }

    private func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func recordCarriesHeaderPayloadAndDecode() throws {
        let sig = DUML.build(sender: 0x09, receiver: 0x2A, seq: 7, cmdType: 0x00, cmdSet: 0x09, cmdId: 0x08, payload: Data([0x55]))
        let pkt = telemetryPacket([sig])
        let rec = try #require(TelemetryRecord.make(packet: pkt, timestamp: Date(timeIntervalSince1970: 1_700_000_000.25)))
        let line = try #require(rec.jsonLine())
        #expect(!line.contains("\n"))
        let o = try object(line)
        #expect(o["t"] as? Double == 1_700_000_000.25)
        #expect(o["type"] as? Int == 1)
        #expect(o["seq"] as? Int == 0x40)
        #expect(o["session"] as? Int == 0x1234)
        #expect(o["payload_hex"] as? String == Telemetry.hex(pkt))
        #expect(o["duml_offset"] as? Int == 26)
        #expect(o["duml_len_prefix_ok"] as? Bool == true)
        let duml = try #require(o["duml"] as? [[String: Any]])
        #expect(duml.count == 1)
        #expect(duml[0]["cmd"] as? String == "09:08")
        #expect(duml[0]["src"] as? String == "09")
        #expect(duml[0]["src_name"] as? String == "hd_link_air#0")
        #expect(duml[0]["payload_hex"] as? String == "55")
        let decoded = try #require(duml[0]["decoded"] as? [String: Any])
        #expect(decoded["kind"] as? String == "hd_link_vt_signal_quality")
        let fields = try #require(decoded["fields"] as? [String: Any])
        #expect(fields["upSignalQuality"] as? Int == 0x55)
    }

    @Test func nanFieldsDoNotDropTheLine() throws {
        // OSD general with NaN lat/lon bit patterns.
        var p = [UInt8](repeating: 0xFF, count: 50)
        p[30] = 0
        let f = DUML.build(sender: 0x03, receiver: 0x2A, seq: 1, cmdType: 0x00, cmdSet: 0x03, cmdId: 0x43, payload: Data(p))
        let rec = try #require(TelemetryRecord.make(packet: telemetryPacket([f]), timestamp: Date()))
        let line = try #require(rec.jsonLine())
        #expect(line.contains("\"nan\""))
    }

    @Test func handshakeReplyWithoutDUML() throws {
        // Mavic-style 8-byte handshake reply (udp_protocol.md example).
        let pkt = Data([0x08, 0x80, 0x3a, 0xdd, 0x00, 0x00, 0x00, 0x6f])
        let o = try object(try #require(TelemetryRecord.make(packet: pkt, timestamp: Date())?.jsonLine()))
        #expect(o["type"] as? Int == 0)
        #expect((o["duml"] as? [Any])?.isEmpty == true)
        #expect(o["duml_offset"] == nil)
    }

    @Test func writerAppendsNonVideoOnlyAndCounts() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gvcli-telem-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let w = try TelemetryDumpWriter(path: path)
        let video = WireProtocol.buildOuter(pktType: 0x02, seq: 8, body: Data(count: 20), sessionId: 1)
        w.record(packet: video)
        w.record(packet: WireProtocol.requestIFrameTelemetry(seq: 16, sessionId: 1))
        w.record(packet: WireProtocol.buildOuter(pktType: 0x00, seq: 0, body: Data(), sessionId: 1))
        w.record(packet: Data([0x01, 0x02])) // too short: ignored
        let summary = w.snapshotAndReset()
        w.close()

        #expect(summary.contains("pkts=2"))
        #expect(summary.contains("2a>bc 02:b3 x1"))
        #expect(summary.contains("t00/no-duml x1"))
        #expect(w.snapshotAndReset().hasPrefix("pkts=0 lines=2"))

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)

        // Re-opening appends rather than truncating.
        let w2 = try TelemetryDumpWriter(path: path)
        w2.record(packet: WireProtocol.requestIFrameTelemetry(seq: 24, sessionId: 1))
        w2.close()
        #expect(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count == 3)
    }
}
