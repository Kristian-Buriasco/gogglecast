import Testing
import Foundation
@testable import GogglesHelper

@Suite("StreamHeadCache and RetryBackoff")
struct StreamHeadCacheTests {
    private func nal(_ tag: UInt8) -> Data { Data([0, 0, 0, 1, tag]) }

    @Test("replays SPS, PPS, IDR in live-delivery order")
    func replayOrder() {
        var c = StreamHeadCache()
        c.record(nal: nal(0x65), nalType: 5)   // arrives out of order on purpose
        c.record(nal: nal(0x68), nalType: 8)
        c.record(nal: nal(0x67), nalType: 7)
        c.record(nal: nal(0x41), nalType: 1)   // P-frames are never cached
        let r = c.replay()
        #expect(r.map(\.nalType) == [7, 8, 5])
        #expect(r.map(\.isParameterSet) == [true, true, false])
        #expect(r.map(\.data) == [nal(0x67), nal(0x68), nal(0x65)])
    }

    @Test("a new IDR or parameter set replaces the old one")
    func newerReplaces() {
        var c = StreamHeadCache()
        c.record(nal: nal(0x67), nalType: 7)
        c.record(nal: nal(0x65), nalType: 5)
        c.record(nal: Data([0, 0, 0, 1, 0x65, 9]), nalType: 5)
        #expect(c.replay().last?.data == Data([0, 0, 0, 1, 0x65, 9]))
        #expect(c.replay().count == 2)
    }

    @Test("not replayable without an IDR or without parameter sets")
    func incompleteIsEmpty() {
        var c = StreamHeadCache()
        c.record(nal: nal(0x67), nalType: 7)
        #expect(c.replay().isEmpty)
        var d = StreamHeadCache()
        d.record(nal: nal(0x65), nalType: 5)
        #expect(d.replay().isEmpty)
    }

    @Test("invalidate clears the cache")
    func invalidate() {
        var c = StreamHeadCache()
        c.record(nal: nal(0x67), nalType: 7)
        c.record(nal: nal(0x65), nalType: 5)
        c.invalidate()
        #expect(c.replay().isEmpty)
        #expect(!c.isReplayable)
    }

    @Test("backoff doubles from 1s and caps at 10s, reset restarts it")
    func backoff() {
        var b = RetryBackoff()
        #expect([b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay(), b.nextDelay()]
                == [1, 2, 4, 8, 10, 10])
        b.reset()
        #expect(b.nextDelay() == 1)
        #expect(RetryBackoff.delay(forAttempt: 1000) == 10)
    }
}
