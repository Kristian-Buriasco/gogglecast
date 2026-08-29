import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.1: XPC interface package (design §5.5). `DeviceInfo` here is the
// XPC-wire counterpart of `GogglesUSB.DeviceInfo` (task 1.5/1.6,
// `Packages/GogglesUSB/Sources/GogglesUSB/RNDISTransport.swift`), not a
// reuse of it. Two reasons this package doesn't just depend on
// `GogglesUSB` and re-export its struct:
//
//   1. `NSXPCConnection` requires reference types conforming to
//      `NSSecureCoding` for anything crossing the XPC boundary (design
//      §5.5) -- a Swift `struct` cannot conform to `NSSecureCoding`
//      (it's an Objective-C-bridging protocol that requires `NSObject`),
//      so a distinct `NSObject` subclass is unavoidable regardless of
//      where it lives.
//   2. Even setting that aside, `GogglesXPC` is meant to be the minimal
//      shared surface linked into three very different targets (a
//      privileged root helper, the sandboxed app, and a Camera Extension
//      running in yet another sandbox -- design §5.5/§6). `GogglesUSB`
//      pulls in libusb/IOKit and is only meaningful inside the helper
//      process that actually owns the USB device; making the app and
//      the camera extension link libusb transitively just to see 7
//      scalar fields is the wrong trade. Duplicating the small field set
//      here keeps `GogglesXPC` dependency-free (Foundation only) and
//      keeps `GogglesUSB` from becoming a public API surface for
//      processes that never touch USB directly.
//
// Field list mirrors `GogglesUSB.DeviceInfo` exactly (all 7 fields):
// product, serial, idVendor, idProduct, bcdDevice, bus, address.
// ─────────────────────────────────────────────────────────────────────────

/// XPC-transportable snapshot of the connected goggles' USB identity,
/// reported by the helper to subscribed clients (design §5.5,
/// `GogglesClientProtocol.deviceChanged`) and returned by
/// `GogglesHelperProtocol.currentDeviceInfo`.
///
/// `NSSecureCoding` conformance is required because this type crosses an
/// `NSXPCConnection` boundary as a reply-block argument / protocol
/// parameter type -- `NSXPCConnection` only accepts `NSObject` subclasses
/// conforming to `NSSecureCoding` (or scalar/`Data`/`String`/etc. types
/// that bridge automatically) for anything beyond those primitives.
public final class DeviceInfo: NSObject, NSSecureCoding {

    public let product: String?
    public let serial: String?
    public let idVendor: UInt16
    public let idProduct: UInt16
    public let bcdDevice: UInt16
    public let bus: UInt8
    public let address: UInt8

    public init(
        product: String?,
        serial: String?,
        idVendor: UInt16,
        idProduct: UInt16,
        bcdDevice: UInt16,
        bus: UInt8,
        address: UInt8
    ) {
        self.product = product
        self.serial = serial
        self.idVendor = idVendor
        self.idProduct = idProduct
        self.bcdDevice = bcdDevice
        self.bus = bus
        self.address = address
    }

    // MARK: - NSSecureCoding

    public static var supportsSecureCoding: Bool { true }

    private enum Key {
        static let product = "product"
        static let serial = "serial"
        static let idVendor = "idVendor"
        static let idProduct = "idProduct"
        static let bcdDevice = "bcdDevice"
        static let bus = "bus"
        static let address = "address"
    }

    public func encode(with coder: NSCoder) {
        coder.encode(product, forKey: Key.product)
        coder.encode(serial, forKey: Key.serial)
        // NSCoder has no fixed-width-unsigned-integer encode overload;
        // widen to Int32/Int for the wire and narrow back on decode. All
        // of these fields fit comfortably (UInt16/UInt8 into Int32).
        coder.encode(Int32(idVendor), forKey: Key.idVendor)
        coder.encode(Int32(idProduct), forKey: Key.idProduct)
        coder.encode(Int32(bcdDevice), forKey: Key.bcdDevice)
        coder.encode(Int32(bus), forKey: Key.bus)
        coder.encode(Int32(address), forKey: Key.address)
    }

    /// Multi-device picker design item 1: mirrors `GogglesUSB.DeviceInfo
    /// .deviceId` exactly (serial when available, else a `bus:address`
    /// composite) -- duplicated here for the same reason the rest of this
    /// file's fields are duplicated rather than shared (see file doc
    /// comment): this package stays dependency-free of `GogglesUSB`.
    /// Opaque to consumers; degrades gracefully across a replug/reboot (a
    /// bus:address-derived ID is not guaranteed stable then) -- never
    /// assume permanence.
    public var deviceId: String {
        if let serial, !serial.isEmpty {
            return "serial:\(serial)"
        }
        return "bus:\(bus):\(address)"
    }

    public required init?(coder: NSCoder) {
        // Type-safe decode methods only (design brief point 2): no
        // `decodeObject(forKey:)`/`decodeInteger(forKey:)`-without-class
        // legacy APIs, which don't participate in `NSSecureCoding`'s
        // class allow-listing and can be pointed at unexpected classes
        // by a malicious/corrupt payload.
        product = coder.decodeObject(of: NSString.self, forKey: Key.product) as String?
        serial = coder.decodeObject(of: NSString.self, forKey: Key.serial) as String?
        idVendor = UInt16(truncatingIfNeeded: coder.decodeInt32(forKey: Key.idVendor))
        idProduct = UInt16(truncatingIfNeeded: coder.decodeInt32(forKey: Key.idProduct))
        bcdDevice = UInt16(truncatingIfNeeded: coder.decodeInt32(forKey: Key.bcdDevice))
        bus = UInt8(truncatingIfNeeded: coder.decodeInt32(forKey: Key.bus))
        address = UInt8(truncatingIfNeeded: coder.decodeInt32(forKey: Key.address))
    }
}
