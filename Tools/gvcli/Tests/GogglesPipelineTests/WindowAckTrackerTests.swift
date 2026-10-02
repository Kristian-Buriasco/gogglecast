// Unit tests for the experimental `WindowAckTracker` (AckMode.cumulativeWindow).

import Testing
@testable import GogglesPipeline

@Suite struct WindowAckTrackerTests {
    @Test func acksEveryNPacketsWithHighestSeq() {
        var t = WindowAckTracker(ackEveryPackets: 3)
        #expect(t.recordPacket(seq: 0x0010) == nil)
        #expect(t.recordPacket(seq: 0x0018) == nil)
        #expect(t.recordPacket(seq: 0x0020) == 0x0020)
        #expect(t.recordPacket(seq: 0x0028) == nil)
    }

    @Test func flushOnlyWhenAdvanced() {
        var t = WindowAckTracker(ackEveryPackets: 100)
        _ = t.recordPacket(seq: 0x0100)
        #expect(t.flush() == 0x0100)
        #expect(t.flush() == nil)
        _ = t.recordPacket(seq: 0x0108)
        #expect(t.flush() == 0x0108)
    }

    @Test func neverRegressesOnLateOrRetransmittedPacket() {
        var t = WindowAckTracker(ackEveryPackets: 100)
        _ = t.recordPacket(seq: 0x0200)
        #expect(t.flush() == 0x0200)
        // A late retransmission of an older packet (low bits = resend marker).
        _ = t.recordPacket(seq: 0x01F1)
        #expect(t.flush() == nil)
        #expect(t.highest == 0x0200)
    }

    @Test func stripsResendMarkerBits() {
        var t = WindowAckTracker(ackEveryPackets: 1)
        #expect(t.recordPacket(seq: 0x0309) == 0x0308)
    }

    @Test func wrapsAround16Bits() {
        var t = WindowAckTracker(ackEveryPackets: 1)
        #expect(t.recordPacket(seq: 0xFFF8) == 0xFFF8)
        #expect(t.recordPacket(seq: 0x0000) == 0x0000)
        #expect(t.recordPacket(seq: 0x0008) == 0x0008)
        // Pre-wrap straggler must not move the window backwards.
        #expect(t.recordPacket(seq: 0xFFF0) == nil)
    }

    @Test func modeParsing() {
        #expect(AckMode(rawValue: "window") == .cumulativeWindow)
        #expect(AckMode(rawValue: "frame") == .frameRange)
        #expect(AckMode(rawValue: "bogus") == nil)
    }
}
