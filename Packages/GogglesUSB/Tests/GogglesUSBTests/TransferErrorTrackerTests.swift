import Testing
@testable import GogglesUSB

@Suite("TransferErrorTracker")
struct TransferErrorTrackerTests {
    @Test("gives up after threshold consecutive failures")
    func givesUpAtThreshold() {
        var t = TransferErrorTracker(threshold: 5)
        for _ in 0..<4 { #expect(t.record(completed: false) == false) }
        #expect(t.record(completed: false) == true)
    }

    @Test("a completed transfer resets the count")
    func completionResets() {
        var t = TransferErrorTracker(threshold: 3)
        _ = t.record(completed: false)
        _ = t.record(completed: false)
        #expect(t.record(completed: true) == false)
        #expect(t.consecutiveFailures == 0)
        _ = t.record(completed: false)
        #expect(t.record(completed: false) == false)
        #expect(t.record(completed: false) == true)
    }
}
