import GogglesXPC

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4 originally put this info in a big standalone card (design §6/plan
// 3.4: "product / serial / `2CA3:0020` / bus-address"). User feedback
// (round 3, live hardware testing) asked for it moved into the same title-
// bar-level row as the status pill instead -- "Name of the goggles and
// serial + small usb mention at the same level of the live bubble card" --
// so this is now a compact, single-line inline chip (`CompactDeviceIdentity`,
// this file's sole content), not a separate full-width card.
// CosmoViewer Direct is a UX reference only (design §6's explicit caveat);
// nothing here is derived from it beyond "a small identity summary."
// ─────────────────────────────────────────────────────────────────────────

/// Product name, serial, and USB ID as one compact inline row -- shown from
/// `.claiming` onward (`GogglesUIStateKind.showsDeviceCard`,
/// `GogglesConnectionView`'s `topIdentityRow`). `info == nil` is a real,
/// renderable state (e.g. `.claiming`, before `currentDeviceInfo`'s first
/// `deviceChanged` callback has landed) -- shown with placeholder text
/// rather than hidden.
struct CompactDeviceIdentity: View {
    let info: DeviceInfo?

    /// design's literal `2CA3:0020` when no device info is known yet
    /// (matches the one VID:PID this app ever expects, design §1); the real
    /// value once `info` is populated, formatted the same way.
    private var usbIDText: String {
        guard let info else { return "2CA3:0020" }
        return String(format: "%04X:%04X", info.idVendor, info.idProduct)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let nick = ProfileStore.shared.nickname(for: info?.serial) {
                Text(nick).font(.subheadline.bold()).foregroundStyle(.white)
                Text("·").foregroundStyle(.secondary)
            }
            Text(info?.product ?? "DJI Goggles 3")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text("·")
                .foregroundStyle(.secondary)
            Text("S/N \(info?.serial ?? "—")")
            Text("·")
                .foregroundStyle(.secondary)
            Text("USB \(usbIDText)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceInfoCard")
    }
}

#Preview("Known device") {
    CompactDeviceIdentity(info: DeviceInfo(
        product: "DJI Goggles 3",
        serial: "ABC123XYZ",
        idVendor: 0x2CA3,
        idProduct: 0x0020,
        bcdDevice: 0x0100,
        bus: 20,
        address: 3
    ))
    .padding()
    .background(Color.black)
}

#Preview("Unknown device (claiming, before deviceChanged)") {
    CompactDeviceIdentity(info: nil)
        .padding()
        .background(Color.black)
}
#endif
