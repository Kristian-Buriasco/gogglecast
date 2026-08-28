import Foundation
import Testing
@testable import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 2.1: proves `DeviceInfo`/`StreamStats`'s `NSSecureCoding`
// implementations are genuinely correct -- not just present -- by round-
// tripping real instances through `NSKeyedArchiver`/`NSKeyedUnarchiver`
// with `requiringSecureCoding: true`, the same archiver mode
// `NSXPCConnection` uses internally to encode/decode arguments. A wrong
// `encode(with:)`/`init?(coder:)` pairing (mismatched keys, wrong decode
// method, missing field) would either throw here or silently produce a
// different value than what was archived -- this test would catch both.
// ─────────────────────────────────────────────────────────────────────────

@Suite("NSSecureCoding round-trip")
struct SecureCodingRoundTripTests {

    @Test("DeviceInfo round-trips through NSKeyedArchiver/Unarchiver")
    func deviceInfoRoundTrip() throws {
        let original = DeviceInfo(
            product: "DJI Goggles",
            serial: "ABC123XYZ",
            idVendor: 0x2CA3,
            idProduct: 0x0020,
            bcdDevice: 0x0100,
            bus: 20,
            address: 3
        )

        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(of: DeviceInfo.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()

        let result = try #require(decoded)
        #expect(result.product == original.product)
        #expect(result.serial == original.serial)
        #expect(result.idVendor == original.idVendor)
        #expect(result.idProduct == original.idProduct)
        #expect(result.bcdDevice == original.bcdDevice)
        #expect(result.bus == original.bus)
        #expect(result.address == original.address)
    }

    @Test("DeviceInfo round-trips with nil product/serial")
    func deviceInfoRoundTripNilFields() throws {
        let original = DeviceInfo(
            product: nil,
            serial: nil,
            idVendor: 0x2CA3,
            idProduct: 0x0020,
            bcdDevice: 0,
            bus: 0,
            address: 0
        )

        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(of: DeviceInfo.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()

        let result = try #require(decoded)
        #expect(result.product == nil)
        #expect(result.serial == nil)
    }

    @Test("StreamStats round-trips through NSKeyedArchiver/Unarchiver")
    func streamStatsRoundTrip() throws {
        let original = StreamStats(
            fps: 56,
            bitrateKbps: 12345.6,
            drops: 2,
            cumulativeFrames: 100_000,
            cumulativeBytes: 4_000_000_000,
            cumulativeDrops: 17
        )

        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(of: StreamStats.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()

        let result = try #require(decoded)
        #expect(result.fps == original.fps)
        #expect(result.bitrateKbps == original.bitrateKbps)
        #expect(result.drops == original.drops)
        #expect(result.cumulativeFrames == original.cumulativeFrames)
        #expect(result.cumulativeBytes == original.cumulativeBytes)
        #expect(result.cumulativeDrops == original.cumulativeDrops)
    }

    @Test("supportsSecureCoding is true for both value types")
    func supportsSecureCodingFlags() {
        #expect(DeviceInfo.supportsSecureCoding)
        #expect(StreamStats.supportsSecureCoding)
    }

    @Test("currentProtocolVersion is a stable positive constant")
    func protocolVersionConstant() {
        #expect(currentProtocolVersion == 1)
    }

    @Test("GogglesState rawValue matches design §6 ordering")
    func gogglesStateRawValues() {
        #expect(GogglesState.noHelper.rawValue == 0)
        #expect(GogglesState.noDevice.rawValue == 1)
        #expect(GogglesState.claiming.rawValue == 2)
        #expect(GogglesState.claimFailed.rawValue == 3)
        #expect(GogglesState.resolving.rawValue == 4)
        #expect(GogglesState.handshaking.rawValue == 5)
        #expect(GogglesState.waitingForKeyframe.rawValue == 6)
        #expect(GogglesState.live.rawValue == 7)
        #expect(GogglesState.stalled.rawValue == 8)
    }
}
