import Testing
@testable import GogglesView
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1 brief, point 4: "The protocol-version mismatch check needs to be
// demonstrably testable, not just present in code with no way to verify it
// fires... given a protocolVersion reply value different from
// currentProtocolVersion, does your code correctly flag the loud-failure
// state? This piece IS unit-testable even if the full XPC round trip
// isn't."
//
// `HelperClient.evaluateProtocolVersion(reported:expected:)` is the exact
// seam this exercises: it's the same pure function
// `applyProtocolVersionResult` calls after a real `protocolVersion(reply:)`
// XPC round trip, but tested here with zero XPC involved -- no
// `NSXPCConnection`, no listener, no helper process.
// ─────────────────────────────────────────────────────────────────────────

@Suite("HelperClient protocol version check")
struct HelperClientProtocolVersionTests {

    @Test("matching versions -> connected")
    func matchingVersionsConnect() {
        let result = HelperClient.evaluateProtocolVersion(reported: currentProtocolVersion, expected: currentProtocolVersion)
        #expect(result == .connected)
    }

    @Test("reported version lower than expected -> versionMismatch, loud")
    func lowerReportedVersionMismatches() {
        let result = HelperClient.evaluateProtocolVersion(reported: 0, expected: currentProtocolVersion)
        #expect(result == .versionMismatch(reported: 0, expected: currentProtocolVersion))
        // Also assert this is *not* silently coerced/ignored into `.connected` --
        // the exact failure the brief calls out ("fails loudly", not
        // quietly).
        #expect(result != .connected)
    }

    @Test("reported version higher than expected -> versionMismatch, loud")
    func higherReportedVersionMismatches() {
        let bogusFutureVersion = currentProtocolVersion + 1
        let result = HelperClient.evaluateProtocolVersion(reported: bogusFutureVersion, expected: currentProtocolVersion)
        #expect(result == .versionMismatch(reported: bogusFutureVersion, expected: currentProtocolVersion))
    }

    @Test("default `expected` parameter is GogglesXPC.currentProtocolVersion")
    func defaultExpectedMatchesPackageConstant() {
        // Exercises the default-argument path specifically (no `expected:`
        // passed), guarding against `HelperClient` and `GogglesXPC` drifting
        // apart on what "the current version" means -- exactly the
        // single-source-of-truth purpose `ProtocolVersion.swift`'s own doc
        // comment describes.
        let mismatchResult = HelperClient.evaluateProtocolVersion(reported: currentProtocolVersion + 5)
        guard case .versionMismatch(let reported, let expected) = mismatchResult else {
            Issue.record("expected .versionMismatch, got \(mismatchResult)")
            return
        }
        #expect(reported == currentProtocolVersion + 5)
        #expect(expected == currentProtocolVersion)

        let matchResult = HelperClient.evaluateProtocolVersion(reported: currentProtocolVersion)
        #expect(matchResult == .connected)
    }
}
