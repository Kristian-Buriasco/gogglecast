// Unit tests for the SPS+IDR started-gate state machine and the dropped-frame
// burst detector (decoder resync fixes).

import Testing
import Foundation
@testable import GogglesPipeline

private func nal(_ type: UInt8, _ tag: UInt8 = 0) -> Data {
    Data([0, 0, 0, 1, type, tag])
}

private func feed(_ g: inout KeyframeGate, _ n: Data) -> GateOutput { g.process(n) }
private func rec(_ d: inout DropBurstDetector, _ total: Int, _ now: Date) -> Bool {
    d.record(droppedTotal: total, now: now)
}

@Suite struct KeyframeGateTests {
    @Test func initialPassThroughSpsThenIdrThenP() {
        var g = KeyframeGate()
        #expect(feed(&g, nal(0x67)).nals.isEmpty)
        #expect(feed(&g, nal(0x68)).nals.isEmpty)
        // P-frame before IDR is dropped
        #expect(feed(&g, nal(0x41)).nals.isEmpty)
        let out = feed(&g, nal(0x65))
        #expect(out.didStart)
        #expect(out.nals == [nal(0x67), nal(0x68), nal(0x65)])
        let p = feed(&g, nal(0x41, 1))
        #expect(!p.didStart)
        #expect(p.nals == [nal(0x41, 1)])
    }

    @Test func idrWithoutParameterSetIsDropped() {
        var g = KeyframeGate()
        #expect(feed(&g, nal(0x65)).nals.isEmpty)
        #expect(!g.started)
    }

    @Test func silenceRearmDropsPFramesUntilNextSpsIdr() {
        var g = KeyframeGate()
        _ = feed(&g, nal(0x67)); _ = feed(&g, nal(0x65))
        #expect(g.started)
        g.rearm()
        #expect(!g.started)
        // Video resumes mid-GOP: P-frames and a stale-less IDR are dropped
        #expect(feed(&g, nal(0x41)).nals.isEmpty)
        #expect(feed(&g, nal(0x65)).nals.isEmpty)   // cached SPS was dropped
        #expect(feed(&g, nal(0x67, 9)).nals.isEmpty)
        let out = feed(&g, nal(0x65, 9))
        #expect(out.didStart)
        #expect(out.nals == [nal(0x67, 9), nal(0x65, 9)])
        #expect(feed(&g, nal(0x41, 2)).nals == [nal(0x41, 2)])
    }

    @Test func sharedGateRearmReportsWhetherItWasOpen() {
        let g = SharedKeyframeGate()
        #expect(g.rearm() == false)
        _ = g.process(nal(0x67)); _ = g.process(nal(0x65))
        #expect(g.started)
        #expect(g.rearm() == true)
        #expect(!g.started)
    }
}

@Suite struct DropBurstDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func singleDropDoesNotRearm() {
        var d = DropBurstDetector(threshold: 3, window: 1, cooldown: 5)
        #expect(!rec(&d, 1, t0))
        #expect(!rec(&d, 1, t0.addingTimeInterval(0.5)))
    }

    @Test func burstRearmsThenCooldownSuppresses() {
        var d = DropBurstDetector(threshold: 3, window: 1, cooldown: 5)
        #expect(!rec(&d, 1, t0))
        #expect(!rec(&d, 2, t0.addingTimeInterval(0.2)))
        #expect(rec(&d, 3, t0.addingTimeInterval(0.4)))
        // Another burst inside the cooldown is ignored
        #expect(!rec(&d, 6, t0.addingTimeInterval(1.0)))
        // After the cooldown a fresh burst fires again
        #expect(rec(&d, 9, t0.addingTimeInterval(6.0)))
    }

    @Test func slowDripOutsideWindowDoesNotRearm() {
        var d = DropBurstDetector(threshold: 3, window: 1, cooldown: 5)
        for i in 1...10 {
            #expect(!rec(&d, i, t0.addingTimeInterval(Double(i) * 2)))
        }
    }
}
