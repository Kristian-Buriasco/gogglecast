import Foundation

/// Placeholder public type so the `GogglesUSB` target has real source
/// content. The libusb + RNDIS transport implementation lands in a later
/// phase; this package is where that libusb dependency will eventually be
/// added (it must never be added to `GogglesProtocol`).
public struct GogglesUSB {
    public init() {}
}
