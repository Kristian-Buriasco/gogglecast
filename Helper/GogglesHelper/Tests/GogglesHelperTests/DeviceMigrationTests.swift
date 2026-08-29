import Testing
@testable import GogglesHelper

// BLOCKER 1 fix (multi-device picker review round 2): pure-logic tests for
// `DeviceMigration.chooseMigrationTarget` -- the decision that lets a
// `bus:address`-derived device (no USB serial) recover automatically after
// an unplug/replug or goggles reboot changes its real bus:address, without
// the wire-facing `deviceId` (which `GogglesConnectionCoordinator`/
// `DevicePickerCoordinator` bind to for their whole lifetime) ever having
// to change. No hardware, no XPC, no libusb involved -- exactly the pure
// logic the design's own verification section calls "exactly the kind of
// pure logic that should be unit-testable without hardware."

@Suite("DeviceMigration.chooseMigrationTarget")
struct DeviceMigrationTests {

    @Test("exactly one unclaimed candidate -> migrates to it")
    func exactlyOneUnclaimedCandidateMigrates() {
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: ["bus:20:5"],
            otherKnownClaimTargets: []
        )
        #expect(result == "bus:20:5")
    }

    @Test("no candidates -> nil (genuinely unplugged, keep waiting)")
    func noCandidatesReturnsNil() {
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: [],
            otherKnownClaimTargets: []
        )
        #expect(result == nil)
    }

    @Test("two+ unclaimed candidates -> nil (ambiguous, never guess)")
    func multipleUnclaimedCandidatesReturnsNil() {
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: ["bus:20:5", "bus:21:2"],
            otherKnownClaimTargets: []
        )
        #expect(result == nil)
    }

    @Test("a candidate already claimed by another known device is excluded")
    func candidateClaimedByAnotherDeviceIsExcluded() {
        // Two devices are simultaneously being tracked (multi-claim); one
        // ("bus:20:3") went stale. "bus:21:9" is already the OTHER
        // tracked device's claim target -- it must never be stolen, even
        // though it's a real currently-enumerated candidate.
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: ["bus:21:9"],
            otherKnownClaimTargets: ["bus:21:9"]
        )
        #expect(result == nil)
    }

    @Test("the stale target itself reappearing in the candidate list is not a migration")
    func staleTargetReappearingIsNotAMigration() {
        // If `currentTarget` is itself among the enumerated candidates, the
        // claim would have succeeded already -- this only matters as a
        // defensive case (the caller only invokes this after a genuine
        // deviceNotFound failure), but the function must not treat
        // "myself" as a migration target.
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: ["bus:20:3"],
            otherKnownClaimTargets: []
        )
        #expect(result == nil)
    }

    @Test("realistic replug scenario: one known device goes stale, one new candidate appears")
    func realisticReplugScenario() {
        // Single-device case (this session's own primary verifiable-
        // without-a-second-unit path): device was at bus:20:3, unplugged
        // and replugged, re-enumerated at bus:20:7. No other devices
        // tracked.
        let result = DeviceMigration.chooseMigrationTarget(
            currentTarget: "bus:20:3",
            enumeratedCandidateIds: ["bus:20:7"],
            otherKnownClaimTargets: []
        )
        #expect(result == "bus:20:7")
    }

    @Test("isBusAddressDerived distinguishes serial-backed IDs from bus:address ones")
    func isBusAddressDerivedDistinguishesIdKinds() {
        #expect(DeviceMigration.isBusAddressDerived("bus:20:3"))
        #expect(!DeviceMigration.isBusAddressDerived("serial:ABC123"))
    }
}
