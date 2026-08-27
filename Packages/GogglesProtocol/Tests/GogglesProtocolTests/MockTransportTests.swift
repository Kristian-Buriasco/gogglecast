// Task 1.4: unit tests for MockTransport's .gvcap parsing/filtering and
// pacing math, independent of the full-pipeline integration test in
// IntegrationTests.swift.

import Testing
import Foundation
@testable import GogglesProtocol

// MARK: - Locating Fixtures/

enum FixturesLocation {
    /// This file lives at
    /// `Packages/GogglesProtocol/Tests/GogglesProtocolTests/MockTransportTests.swift`;
    /// walking up 5 directories from the file reaches the repo root, where
    /// `Fixtures/` lives -- same pattern as `GoldenVectors.goldenJSONURL`.
    static func url(_ relativePath: String, callerFilePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: callerFilePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
    }
}

// MARK: - .gvcap parsing / filtering

@Test func mockTransportLoadsOnlyInboundUDP9003Payloads() throws {
    let records = try MockTransport.loadInboundRecords(capturePath: FixturesLocation.url("clean-start.gvcap"))
    #expect(!records.isEmpty)
    // Every yielded "frame" must be a bare UDP payload (starts with the
    // 8-byte outer header: pktType lives at local offset 6), never a raw
    // Ethernet frame -- i.e. no Ethernet/ARP/IP bytes leaking through.
    for record in records.prefix(50) {
        #expect(record.payload.count >= 8, "every record should at least contain the 8-byte outer header")
    }
    // Timestamps must be non-decreasing (recording order == on-disk order).
    var previous: Double?
    for record in records {
        if let previous {
            #expect(record.timestamp >= previous)
        }
        previous = record.timestamp
    }
}

@Test func mockTransportBadMagicThrows() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).gvcap")
    try Data("NOTAGVCAP".utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(throws: MockTransport.GVCAPError.self) {
        _ = try MockTransport.loadInboundRecords(capturePath: tmp)
    }
}

@Test func mockTransportTruncatedFileThrows() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trunc-\(UUID()).gvcap")
    // Magic + a record header claiming a 100-byte frame, but no frame bytes.
    var bytes = Array("GVCAP001".utf8)
    bytes += [UInt8](repeating: 0, count: 8) // timestamp
    bytes.append(0x00) // direction: inbound
    bytes += [100, 0, 0, 0] // frame_len = 100, LE
    try Data(bytes).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(throws: MockTransport.GVCAPError.self) {
        _ = try MockTransport.loadInboundRecords(capturePath: tmp)
    }
}

// MARK: - inbound stream actually yields parsed records

@Test func mockTransportInboundStreamYieldsAllRecordsImmediatePacing() async throws {
    let transport = try MockTransport(capturePath: FixturesLocation.url("clean-start.gvcap"), pacing: .immediate)
    let expected = try MockTransport.loadInboundRecords(capturePath: FixturesLocation.url("clean-start.gvcap"))

    var received: [Data] = []
    for await frame in transport.inbound {
        received.append(frame)
    }
    #expect(received.count == expected.count)
    #expect(received.first == expected.first?.payload)
    #expect(received.last == expected.last?.payload)
}

@Test func mockTransportSendIsRecordingStub() throws {
    let transport = try MockTransport(capturePath: FixturesLocation.url("clean-start.gvcap"), pacing: .immediate)
    let frame = Data([0x01, 0x02, 0x03])
    try transport.send(frame)
    #expect(transport.sentFrames == [frame])
}

// MARK: - pacing math

@Test func scaledDelayRealTimePassesThroughUnchanged() {
    #expect(MockTransport.scaledDelay(0.5, pacing: .realTime) == 0.5)
}

@Test func scaledDelayImmediateIsAlwaysZero() {
    #expect(MockTransport.scaledDelay(0.5, pacing: .immediate) == 0)
    #expect(MockTransport.scaledDelay(0, pacing: .immediate) == 0)
}

@Test func scaledDelayAcceleratedDividesAndCaps() {
    // 1.0s at 100x -> 0.01s, under the 0.05s cap -> passes through divided.
    #expect(MockTransport.scaledDelay(1.0, pacing: .accelerated(multiplier: 100, maxDelay: 0.05)) == 0.01)
    // 10.0s at 100x -> 0.1s, over the 0.05s cap -> clamped to the cap.
    #expect(MockTransport.scaledDelay(10.0, pacing: .accelerated(multiplier: 100, maxDelay: 0.05)) == 0.05)
}
