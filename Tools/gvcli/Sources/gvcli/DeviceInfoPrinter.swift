import Foundation
import GogglesUSB

/// Prints `deviceInfo` in the same box-drawing banner format
/// `stream.py`'s `main()` prints at startup, so `gvcli info`/`gvcli
/// stream`'s output is directly comparable to the Python prototype's.
func printDeviceInfoBanner(_ info: DeviceInfo) {
    let product = info.product ?? "?"
    let serial = info.serial ?? "?"
    let usbId = String(format: "%04x:%04x", info.idVendor, info.idProduct)
    let bcd = String(format: "0x%04x", info.bcdDevice)
    print("┌─────────────────────────────────────────────")
    print("│ Device:   \(product)")
    print("│ S/N:      \(serial)")
    print("│ USB ID:   \(usbId)  (bcdDevice \(bcd))")
    print(String(format: "│ USB Port: Bus %03d Address %03d", info.bus, info.address))
    print("└─────────────────────────────────────────────")
}
