import Foundation

// ─────────────────────────────────────────────────────────────────────────
// BLOCKER 1 fix (multi-device picker review round 2): a bus:address-derived
// `deviceId` (no USB serial -- `RNDISTransport.swift`'s own doc comment:
// serial is "frequently nil on this hardware") is NOT stable across an
// unplug/replug or a goggles reboot -- the OS assigns a fresh bus/address
// on re-enumeration. Before this fix, `HelperService` used the wire-facing
// `deviceId` directly as the `RNDISTransport(targetDeviceId:)` claim
// target, so a replug/reboot made `scheduleDeviceRetry` poll for an ID that
// could never match again -- a genuine regression of Task 3.7's
// hardware-verified unplug/replug/reboot-MAC-rotation recovery scenarios,
// and a violation of the design's own explicit constraint ("device ID must
// degrade gracefully on bus:address changes -- never assume permanence"),
// which was previously satisfied only in doc comments, nowhere in code.
//
// Fix shape: `HelperService.DeviceState` splits `deviceId` (the stable,
// wire-facing identifier reported to clients -- assigned once, at
// `DeviceState` creation, and never changed) from `claimTarget` (what
// `RNDISTransport(targetDeviceId:)` actually tries to match RIGHT NOW --
// initially equal to `deviceId`, but free to change). When a claim attempt
// against a bus:address-derived `claimTarget` fails with `deviceNotFound`,
// `HelperService` re-enumerates and asks `chooseMigrationTarget` (this
// file, pure logic, unit-tested without hardware) whether exactly one
// currently-connected, not-otherwise-claimed candidate exists -- if so,
// that's treated as "this same physical unit, reappeared with a different
// bus:address" and `claimTarget` is updated to it, while `deviceId` (and
// therefore every client-visible identity -- `GogglesConnectionCoordinator`
// bound to it, `HelperClient.streamingDeviceId`) never changes. This is
// deliberately conservative: ambiguous situations (0, or 2+ unclaimed
// candidates) return `nil` and leave the caller retrying the stale target,
// never guessing which of several devices is "the" one that moved.
//
// A serial-derived `deviceId` never needs migration -- the serial is
// stable across replug/reboot by construction, so `claimTarget` staying
// equal to `deviceId` forever already recovers correctly (this mirrors
// pre-multi-device behavior for that case exactly).
// ─────────────────────────────────────────────────────────────────────────

enum DeviceMigration {

    /// Prefix `GogglesXPC.DeviceInfo.deviceId`/`GogglesUSB.DeviceInfo
    /// .deviceId` use for a serial-backed ID -- see either type's doc
    /// comment. Devices with this prefix never need migration.
    static let serialDeviceIdPrefix = "serial:"

    /// `true` for a `bus:address`-derived ID (no serial) -- the only kind
    /// migration ever applies to.
    static func isBusAddressDerived(_ deviceId: String) -> Bool {
        !deviceId.hasPrefix(serialDeviceIdPrefix)
    }

    /// Decides whether a lost `bus:address`-derived device should be
    /// treated as having reappeared under a new `bus:address`.
    ///
    /// - Parameters:
    ///   - currentTarget: this device's own (now-stale) claim target --
    ///     excluded from the candidate pool (if it were still present,
    ///     there'd be nothing to migrate).
    ///   - enumeratedCandidateIds: every `2CA3:0020` device's `.deviceId`
    ///     currently on the bus (from `GogglesDeviceEnumerator.enumerate()`).
    ///   - otherKnownClaimTargets: every OTHER currently-tracked device's
    ///     own `claimTarget` -- a candidate already accounted for by a
    ///     different device must never be stolen from it.
    /// - Returns: the new claim target, only when exactly one unclaimed
    ///   candidate exists; `nil` otherwise (0 candidates: genuinely
    ///   unplugged, keep waiting; 2+: ambiguous, don't guess).
    static func chooseMigrationTarget(
        currentTarget: String,
        enumeratedCandidateIds: [String],
        otherKnownClaimTargets: Set<String>
    ) -> String? {
        let unclaimed = Set(enumeratedCandidateIds)
            .subtracting(otherKnownClaimTargets)
            .subtracting([currentTarget])
        guard unclaimed.count == 1 else { return nil }
        return unclaimed.first
    }
}
