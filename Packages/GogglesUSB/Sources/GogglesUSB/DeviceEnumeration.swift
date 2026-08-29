import Foundation
import CLibusb

// ─────────────────────────────────────────────────────────────────────────
// Multi-device picker design, item 2: real device enumeration, replacing
// `libusb_open_device_with_vid_pid`'s first-match behavior for the picker's
// "see all connected units" list. Uses `libusb_get_device_list` +
// descriptor filtering on VID:PID 2CA3:0020, producing a `DeviceInfo` for
// every currently-connected candidate WITHOUT fully claiming any of them
// (no `libusb_claim_interface` call anywhere in this file).
//
// Design's own open question ("can the USB serial string descriptor be
// read via a non-exclusive open, or does reading it require the same claim
// that excludes other consumers?") -- answer, reasoned from libusb/USB
// semantics and confirmed against the one physical unit available this
// session (enumerated successfully *while* that same device was actively
// claimed and streaming via a separate `RNDISTransport`, see the task
// report): `libusb_open` alone (no `libusb_claim_interface`) only opens a
// device handle for control transfers on endpoint 0, which string
// descriptor reads use -- it does not claim any interface, and multiple
// libusb handles to the same device (even across processes) can coexist as
// long as none of them are contending over the *same* claimed interface.
// So yes: enumeration can read `product`/`serial` without excluding, or
// being excluded by, a concurrent claim of IF0/IF1 elsewhere. This could
// only be verified end-to-end with a single physical unit tonight (no
// second unit to enumerate side-by-side) -- see the task report for the
// exact scope of what was and wasn't hardware-verified.
// ─────────────────────────────────────────────────────────────────────────

public enum GogglesDeviceEnumerator {

    /// Lists every currently-connected `2CA3:0020` USB device, with as much
    /// `DeviceInfo` as can be read via a non-exclusive `libusb_open` (no
    /// interface claim). `product`/`serial` may be `nil` for a given entry
    /// if opening that specific device or reading its string descriptors
    /// fails (e.g. permissions) -- `bus`/`address`/`idVendor`/`idProduct`/
    /// `bcdDevice` always come from the device list's own descriptor, no
    /// open required for those.
    ///
    /// Returns an empty array (never throws) on any libusb-context-level
    /// failure -- "no devices found" and "libusb itself couldn't even
    /// start" are both represented the same way to a caller that just wants
    /// a device list, matching `enumerateDevices`'s XPC contract (design
    /// item 5: `[DeviceInfo]`, no error channel).
    public static func enumerate() -> [DeviceInfo] {
        var contextPtr: OpaquePointer?
        guard libusb_init(&contextPtr) == 0, let context = contextPtr else { return [] }
        defer { libusb_exit(context) }

        var listPtr: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &listPtr)
        guard count >= 0, let listPtr else { return [] }
        defer { libusb_free_device_list(listPtr, 1) }

        var results: [DeviceInfo] = []
        for i in 0..<Int(count) {
            guard let device = listPtr[i] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
            guard descriptor.idVendor == RNDISTransport.vendorID,
                  descriptor.idProduct == RNDISTransport.productID else { continue }

            let bus = libusb_get_bus_number(device)
            let address = libusb_get_device_address(device)

            var product: String?
            var serial: String?
            var handle: OpaquePointer?
            // Non-exclusive open -- deliberately no libusb_claim_interface
            // call. Best-effort: a failure here (e.g. another process
            // already has an exclusive-mode handle open in a way this
            // platform doesn't like, or a permissions issue) still yields a
            // DeviceInfo entry, just without product/serial -- bus/address
            // alone is enough for `DeviceInfo.deviceId`'s fallback.
            if libusb_open(device, &handle) == 0, let handle {
                product = RNDISTransport.stringDescriptor(handle: handle, index: descriptor.iProduct)
                serial = RNDISTransport.stringDescriptor(handle: handle, index: descriptor.iSerialNumber)
                libusb_close(handle)
            }

            results.append(DeviceInfo(
                product: product, serial: serial,
                idVendor: descriptor.idVendor, idProduct: descriptor.idProduct, bcdDevice: descriptor.bcdDevice,
                bus: bus, address: address
            ))
        }
        return results
    }
}
