import Testing
import Foundation
import GogglesProtocol
@testable import GVNetCore

@Suite struct StreamSessionTests {
    /// A video packet: outer header + 12-byte sub-header + payload.
    private func video(seq: UInt16, frame: UInt8, count: Int, index: Int, payload: [UInt8], session: UInt16 = 1) -> Data {
        var sub = [UInt8](repeating: 0, count: 12)
        sub[8] = frame
        sub[9] = UInt8(count & 0x7F) | UInt8((index & 1) << 7)
        sub[10] = UInt8((index >> 1) & 0x1F)
        return WireProtocol.buildOuter(pktType: WireProtocol.packetTypeVideo, seq: seq, body: Data(sub + payload), sessionId: session)
    }

    private let sps: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2]
    private let pps: [UInt8] = [0, 0, 0, 1, 0x68, 3]
    private let idr: [UInt8] = [0, 0, 0, 1, 0x65, 9, 9, 9]
    private let pframe: [UInt8] = [0, 0, 0, 1, 0x41, 7]

    @Test func startSendsHandshake() {
        var s = StreamSession(sessionId: 0x1234)
        let out = s.start()
        #expect(out.count == 1)
        let p = WireProtocol.parseOuter(out[0])
        #expect(p?.pktType == WireProtocol.packetTypeHandshake)
        #expect(p?.sessionId == 0x1234)
        #expect(out[0].count == 48)
    }

    @Test func outputWaitsForSpsPpsIdrThenFlows() {
        var s = StreamSession(sessionId: 1)
        let t = Date()
        var seq: UInt16 = 0
        func feed(_ nal: [UInt8], frame: UInt8) -> SessionActions {
            defer { seq &+= 8 }
            return s.receive(video(seq: seq, frame: frame, count: 1, index: 0, payload: nal), now: t)
        }
        #expect(feed(pframe, frame: 0).nals.isEmpty)       // before any keyframe: dropped
        #expect(feed(sps, frame: 1).nals.isEmpty)
        #expect(feed(pps, frame: 2).nals.isEmpty)
        let started = feed(idr, frame: 3)
        #expect(started.nals == [Data(sps), Data(pps), Data(idr)])
        #expect(s.started)
        #expect(feed(pframe, frame: 4).nals == [Data(pframe)])
    }

    @Test func fragmentsAreReassembled() {
        var s = StreamSession(sessionId: 1)
        let t = Date()
        _ = s.receive(video(seq: 0, frame: 5, count: 2, index: 0, payload: Array(sps.prefix(4)) + [0x67]), now: t)
        let done = s.receive(video(seq: 8, frame: 5, count: 2, index: 1, payload: [1, 2]), now: t)
        #expect(done.nals.isEmpty) // SPS alone is held until an IDR arrives
        #expect(s.videoPackets == 2)
    }

    @Test func acksAdvanceAndCarryTheSessionId() {
        var s = StreamSession(sessionId: 0xBEEF)
        let t = Date()
        var replies: [Data] = []
        for i in 0..<8 {
            replies += s.receive(video(seq: UInt16(i * 8), frame: UInt8(i), count: 1, index: 0, payload: pframe), now: t).replies
        }
        #expect(!replies.isEmpty)
        let p = WireProtocol.parseOuter(replies[0])!
        #expect(p.pktType == WireProtocol.packetTypeAck)
        #expect(p.sessionId == 0xBEEF)
    }

    @Test func retransmissionBitsAreStrippedFromTheAck() {
        var s = StreamSession(sessionId: 1)
        let a = s.receive(video(seq: 0x0041, frame: 0, count: 1, index: 0, payload: idr), now: Date()) // resent once
        #expect(a.replies.count == 1)
        let body = WireProtocol.parseOuter(a.replies[0])!.body
        #expect(body[body.startIndex] == 0x40 && body[body.startIndex + 1] == 0x00)
    }

    @Test func silenceResendsHandshakeAndRearmsTheGate() {
        let t0 = Date()
        var s = StreamSession(sessionId: 1, now: t0)
        _ = s.start(now: t0)
        _ = s.receive(video(seq: 0, frame: 1, count: 1, index: 0, payload: sps), now: t0)
        _ = s.receive(video(seq: 8, frame: 2, count: 1, index: 0, payload: pps), now: t0)
        _ = s.receive(video(seq: 16, frame: 3, count: 1, index: 0, payload: idr), now: t0)
        #expect(s.started)
        #expect(s.tick(now: t0.addingTimeInterval(1)).allSatisfy { WireProtocol.parseOuter($0)?.pktType != WireProtocol.packetTypeHandshake })
        let out = s.tick(now: t0.addingTimeInterval(2.5))
        #expect(out.contains { WireProtocol.parseOuter($0)?.pktType == WireProtocol.packetTypeHandshake })
        #expect(!s.started)
    }

    @Test func garbageIsIgnored() {
        var s = StreamSession(sessionId: 1)
        #expect(s.receive(Data([1, 2, 3]), now: Date()) == SessionActions())
        #expect(s.receive(WireProtocol.buildOuter(pktType: 0x01, seq: 0, body: Data(count: 30), sessionId: 1), now: Date()).nals.isEmpty)
    }
}
