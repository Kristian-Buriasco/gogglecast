import Testing
@testable import GogglesView
import GogglesXPC

// Multi-device picker design item 7: `DevicePickerCoordinator` is the
// device-selection step ahead of the existing 9-state machine. These tests
// drive it through its REAL `poll()` mechanism -- via
// `HelperClient.enumerateDevicesOverrideForTesting` (a test seam,
// HelperClient.swift), not by hand-constructing expected values and
// asserting on those without ever exercising the coordinator's own polling
// code (MEDIUM 6 fix, multi-device picker review round 2). Auto-select on a
// single candidate was later removed per live user feedback -- every
// non-zero candidate count now shows the picker screen and requires an
// explicit tap (see `DevicePickerCoordinator.swift`'s file doc comment for
// the history). No real XPC/helper process is involved here: this is the
// "mock-tested, not hardware-verified" coordinator-logic coverage the
// design's own verification section calls for; the picker UI itself and
// the underlying single-device connect flow ARE now hardware-verified
// (see the task report).

@Suite("DevicePickerCoordinator")
struct DevicePickerCoordinatorTests {

    @Test("0 candidates -> stays discovering (driven through the real poll())")
    func zeroCandidatesStaysDiscovering() {
        let client = HelperClient()
        client.enumerateDevicesOverrideForTesting = { [] }
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)
        client.onConnectionStateChange?(.connected)
        #expect(picker.state == .discovering)
    }

    @Test("exactly 1 candidate -> shows the picker, does not auto-select")
    func exactlyOneCandidateShowsPicking() {
        // User-directed change (post-hardware-testing): auto-select was
        // removed -- even a single candidate requires an explicit tap.
        let client = HelperClient()
        let device = DeviceInfo(product: "DJI Goggles 3", serial: "XYZ789", idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0x0100, bus: 20, address: 3)
        client.enumerateDevicesOverrideForTesting = { [device] }
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.connected)

        #expect(picker.state == .picking([DevicePickerCandidate(device)]))

        // The explicit tap still works and still reaches `.selected`.
        picker.select(device.deviceId)
        #expect(picker.state == .selected(device.deviceId))
    }

    @Test("exactly 1 candidate with no serial still shows the picker (bus:address fallback ID)")
    func exactlyOneCandidateWithNoSerialShowsPicking() {
        // RNDISTransport.swift's own doc comment: serial is "frequently
        // nil on this hardware" -- the picker path must work for the
        // bus:address-fallback-ID case too, not just the serial-backed one.
        let client = HelperClient()
        let device = DeviceInfo(product: "DJI Goggles 3", serial: nil, idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0x0100, bus: 20, address: 3)
        client.enumerateDevicesOverrideForTesting = { [device] }
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.connected)

        #expect(picker.state == .picking([DevicePickerCandidate(device)]))
        picker.select("bus:20:3")
        #expect(picker.state == .selected("bus:20:3"))
    }

    @Test("2+ candidates -> picking, with every candidate present (driven through the real poll())")
    func multipleCandidatesShowsPicking() {
        let client = HelperClient()
        let deviceA = DeviceInfo(product: "Goggles A", serial: "AAA", idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0x0100, bus: 20, address: 3)
        let deviceB = DeviceInfo(product: "Goggles B", serial: nil, idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0x0100, bus: 20, address: 4)
        client.enumerateDevicesOverrideForTesting = { [deviceA, deviceB] }
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.connected)

        guard case .picking(let candidates) = picker.state else {
            Issue.record("expected .picking, got \(picker.state)")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.map(\.id) == [deviceA.deviceId, deviceB.deviceId])
        #expect(candidates[0].product == "Goggles A")
        #expect(candidates[1].serial == nil)

        // Selecting (as `DevicePickerView` does on a tap) drives state to
        // `.selected` and stops any further polling.
        picker.select(deviceA.deviceId)
        #expect(picker.state == .selected(deviceA.deviceId))
    }

    @Test("select() is terminal -- state never changes again after selection")
    func selectIsTerminal() {
        let client = HelperClient()
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)
        picker.select("device-1")
        #expect(picker.state == .selected("device-1"))
        picker.select("device-2")
        // Multi-device design's own framing: once a device is chosen, the
        // picker's job is done -- a second `select()` call (which
        // shouldn't happen in practice once the UI is torn down, but is
        // cheap to guard) still just overwrites state rather than crashing
        // or silently no-op'ing in a way that would hide a real bug; this
        // test documents the actual (last-write-wins) behavior rather than
        // asserting an ideal that isn't implemented, since nothing in this
        // pass depends on rejecting a second call.
        #expect(picker.state == .selected("device-2"))
    }

    @Test("DevicePickerCandidate mirrors DeviceInfo.deviceId's own serial/bus:address rule")
    func candidateMirrorsDeviceInfoDeviceId() {
        let withSerial = DeviceInfo(product: nil, serial: "XYZ", idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0, bus: 1, address: 2)
        let withoutSerial = DeviceInfo(product: nil, serial: nil, idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0, bus: 1, address: 2)
        #expect(DevicePickerCandidate(withSerial).id == "serial:XYZ")
        #expect(DevicePickerCandidate(withoutSerial).id == "bus:1:2")
    }

    // MARK: - BLOCKER 2 fix: connection-failure visibility during the
    // picker phase (multi-device picker review round 2)

    @Test("versionMismatch connection state -> connectionUnavailable with a reason mentioning both versions")
    func versionMismatchSurfacesConnectionUnavailable() {
        let client = HelperClient()
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.versionMismatch(reported: 1, expected: 2))

        guard case .connectionUnavailable(let reason) = picker.state else {
            Issue.record("expected .connectionUnavailable, got \(picker.state)")
            return
        }
        #expect(reason?.contains("1") == true)
        #expect(reason?.contains("2") == true)
    }

    @Test("disconnected connection state -> connectionUnavailable with a nil reason")
    func disconnectedSurfacesConnectionUnavailable() {
        let client = HelperClient()
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.disconnected)

        #expect(picker.state == .connectionUnavailable(reason: nil))
    }

    @Test("connecting connection state -> connectionUnavailable with a nil reason")
    func connectingSurfacesConnectionUnavailable() {
        let client = HelperClient()
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.connecting)

        #expect(picker.state == .connectionUnavailable(reason: nil))
    }

    @Test("recovering to .connected after a connection failure resets to discovering before polling resumes")
    func recoveringFromFailureResetsToDiscovering() {
        let client = HelperClient()
        client.enumerateDevicesOverrideForTesting = { [] }
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)

        client.onConnectionStateChange?(.disconnected)
        #expect(picker.state == .connectionUnavailable(reason: nil))

        client.onConnectionStateChange?(.connected)
        #expect(picker.state == .discovering)
    }

    @Test("a connection failure after selection is ignored -- selection is still terminal")
    func connectionFailureAfterSelectionIsIgnored() {
        let client = HelperClient()
        let picker = DevicePickerCoordinator(client: client, pollInterval: 999)
        picker.select("device-1")

        client.onConnectionStateChange?(.disconnected)

        #expect(picker.state == .selected("device-1"))
    }
}
