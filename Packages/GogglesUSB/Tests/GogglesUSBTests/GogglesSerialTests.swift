import XCTest
@testable import GogglesUSB

final class GogglesSerialTests: XCTestCase {
    func testSerialIsTheTailOfTheProductName() {
        XCTAssertEqual(GogglesSerial.resolve(usbSerial: "987654321ABCDEF", product: "Goggles3-753XM567024TS7"), "753XM567024TS7")
        XCTAssertEqual(GogglesSerial.resolve(usbSerial: "987654321ABCDEF", product: "Goggles_N3 -8HAXNC40A72W0X"), "8HAXNC40A72W0X")
    }

    func testARealUSBSerialWins() {
        XCTAssertEqual(GogglesSerial.resolve(usbSerial: "ABC12345", product: "Goggles3-753XM567024TS7"), "ABC12345")
    }

    func testPlaceholderWithoutAUsableProductGivesNilSoTheBusAddressFallbackIsUsed() {
        XCTAssertNil(GogglesSerial.resolve(usbSerial: "987654321ABCDEF", product: nil))
        XCTAssertNil(GogglesSerial.resolve(usbSerial: "987654321ABCDEF", product: "Goggles 3"))
        XCTAssertNil(GogglesSerial.resolve(usbSerial: nil, product: "USB2.0 Hub"))
        XCTAssertNil(GogglesSerial.resolve(usbSerial: "", product: nil))
    }

    func testTwoGogglesGetDifferentDeviceIds() {
        func info(_ product: String, bus: UInt8, address: UInt8) -> DeviceInfo {
            DeviceInfo(product: product, serial: "987654321ABCDEF", idVendor: 0x2CA3, idProduct: 0x0020, bcdDevice: 0, bus: bus, address: address)
        }
        let a = info("Goggles3-753XM567024TS7", bus: 1, address: 4)
        let b = info("Goggles3-753XM567099ZZ1", bus: 1, address: 6)
        XCTAssertNotEqual(a.deviceId, b.deviceId)
        XCTAssertEqual(a.deviceId, "serial:753XM567024TS7")
        // the same unit keeps its ID after a replug on another port
        XCTAssertEqual(a.deviceId, info("Goggles3-753XM567024TS7", bus: 2, address: 9).deviceId)
    }
}
