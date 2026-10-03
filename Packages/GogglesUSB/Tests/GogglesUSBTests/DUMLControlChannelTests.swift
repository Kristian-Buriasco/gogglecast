import Testing
import Foundation
@testable import GogglesUSB
import GogglesProtocol

@Suite("DUMLControlChannel battery parsing")
struct DUMLControlChannelTests {

    /// 33-byte payload shaped like the hardware-captured reply (status 0,
    /// byte 21 = percentage).
    static func replyPayload(percent: UInt8, status: UInt8 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 33)
        bytes[0] = status
        bytes[21] = percent
        return Data(bytes)
    }

    static func reply(seq: UInt16, payload: Data, sender: UInt8 = 0x59) -> Data {
        DUML.build(sender: sender, receiver: 0x2A, seq: seq, cmdType: 0xC0, cmdSet: 0x0D, cmdId: 0x02, payload: payload)
    }

    @Test("byte 21 of an ok reply is the percentage")
    func parsesPercent() {
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Self.replyPayload(percent: 0x5B)) == 91)
    }

    @Test("rejects short, error-status, and out-of-range payloads")
    func rejectsBad() {
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Data([0xE0])) == nil)
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Data(repeating: 0, count: 21)) == nil)
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Self.replyPayload(percent: 50, status: 1)) == nil)
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Self.replyPayload(percent: 200)) == nil)
        #expect(DUMLControlChannel.batteryPercent(fromReplyPayload: Data(repeating: 0, count: 22)) == 0)
    }

    @Test("query sends 0D:02 to 0x59 and matches the reply by seq, skipping heartbeat and partial frames")
    func queryRoundTrip() {
        var sent: [Data] = []
        var reads: [Data] = []
        let channel = DUMLControlChannel(
            write: { frame in
                sent.append(frame)
                let seq = DUML.parseStream(frame).packets[0].seq
                let heartbeat = DUML.build(sender: 0x3C, receiver: 0x2A, seq: 7, cmdType: 0x00, cmdSet: 0x00, cmdId: 0x82)
                let stale = DUMLControlChannelTests.reply(seq: seq &- 1, payload: DUMLControlChannelTests.replyPayload(percent: 10))
                let good = DUMLControlChannelTests.reply(seq: seq, payload: DUMLControlChannelTests.replyPayload(percent: 91))
                let all = heartbeat + stale + good
                // Split mid-frame to exercise tail carry-over.
                reads = [Data(), all.prefix(20), all.dropFirst(20)]
                return true
            },
            read: { _ in reads.isEmpty ? Data() : reads.removeFirst() },
            initialSeq: 0x1234
        )
        #expect(channel.queryBatteryPercent(timeout: 1) == 91)
        let req = DUML.parseStream(sent[0]).packets[0]
        #expect(req.sender == 0x2A && req.receiver == 0x59 && req.cmdType == 0x40)
        #expect(req.cmdSet == 0x0D && req.cmdId == 0x02 && req.payload.isEmpty)
        #expect(req.seq == 0x1235)
    }

    @Test("error reply (0xE0) yields nil; read failure yields nil")
    func queryFailures() {
        var reads: [Data] = []
        let channel = DUMLControlChannel(
            write: { frame in
                let seq = DUML.parseStream(frame).packets[0].seq
                reads = [DUMLControlChannelTests.reply(seq: seq, payload: Data([0xE0]))]
                return true
            },
            read: { _ in reads.isEmpty ? Data() : reads.removeFirst() }
        )
        #expect(channel.queryBatteryPercent(timeout: 0.3) == nil)

        let broken = DUMLControlChannel(write: { _ in true }, read: { _ in nil })
        #expect(broken.queryBatteryPercent(timeout: 0.3) == nil)
        let noWrite = DUMLControlChannel(write: { _ in false }, read: { _ in Data() })
        #expect(noWrite.queryBatteryPercent(timeout: 0.3) == nil)
    }
}
