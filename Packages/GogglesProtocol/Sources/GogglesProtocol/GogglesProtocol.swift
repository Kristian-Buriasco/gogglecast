import Foundation

/// Placeholder public type so the `GogglesProtocol` target has real source
/// content. Protocol parsing/encoding logic lands in later phases.
///
/// This package must remain pure Swift + Foundation only: no libusb, no
/// AppKit, no other Apple frameworks. That constraint is what makes offline
/// testing (see docs, §9.1) possible and what lets a Wi-Fi transport drop in
/// later without touching this package.
public struct GogglesProtocol {
    public init() {}
}
