import Foundation
import IOKit

/// Detects whether DJI Goggles 3 (VID 0x2CA3, PID 0x0020, the same IDs the
/// helper's `GogglesDeviceEnumerator` filters on) are on the USB bus, using a
/// read-only IOKit registry lookup in the app itself. It does not need the
/// background service and does not claim anything, so the setup assistant can
/// tell "nothing on USB" apart from "seen but can't take control".
enum GogglesUSBPresence {
    static let vendorID = 0x2CA3
    static let productID = 0x0020

    static func isPresent() -> Bool {
        count() > 0
    }

    static func count() -> Int {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return 0 }
        matching["idVendor"] = vendorID
        matching["idProduct"] = productID
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes the matching dictionary.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var n = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            n += 1
        }
        return n
    }
}
