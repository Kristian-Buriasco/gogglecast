import Foundation
import Testing
@testable import GogglesView

@Suite struct PictureChangeGateTests {
    private func s(_ sig: UInt64, luma: Double = 90) -> PictureWatch.Sample { .init(luma: luma, signature: sig) }

    /// Feeds the samples in order and returns the gate's answer for each.
    private func run(_ samples: [PictureWatch.Sample?]) -> [Bool] {
        var g = PictureChangeGate()
        return samples.map { g.observe($0) }
    }

    @Test func startsOnlyAfterSeveralChanges() {
        #expect(run([s(1), s(2), s(3), s(4)]) == [false, false, false, true], "three changes in a row")
    }

    @Test func aStaticPictureNeverStarts() {
        #expect(!run(Array(repeating: s(7), count: 50)).contains(true))
    }

    @Test func aRepeatedFrameRestartsTheCount() {
        #expect(run([s(1), s(2), s(3), s(3), s(4), s(5), s(6)]) == [false, false, false, false, false, false, true])
    }

    @Test func blackOrMissingPicturesNeverCountAndReset() {
        #expect(run([s(1), s(2), s(3, luma: 2), nil, s(4), s(5), s(6), s(7)]) == [false, false, false, false, false, false, false, true])
    }
}
