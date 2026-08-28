import GogglesXPC

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4: the device-info card (design §6/plan 3.4: "product / serial /
// `2CA3:0020` / bus-address ... styled after CosmoViewer Direct's layout").
// CosmoViewer Direct is a UX reference only (design §6's explicit caveat,
// copied into the task brief) -- nothing about its internals is known and
// nothing here is derived from it beyond "a small identity summary card."
// ─────────────────────────────────────────────────────────────────────────

/// Product/serial/VID:PID/bus-address summary, shown from `.claiming`
/// onward (`GogglesUIStateKind.showsDeviceCard`). `info == nil` is a real,
/// renderable state (e.g. `.claiming`, before `currentDeviceInfo`'s first
/// `deviceChanged` callback has landed) -- shown with placeholder text
/// rather than hidden, so the card's presence itself stays a reliable
/// "we're past `noDevice`" signal across every state that should show it.
struct DeviceInfoCard: View {
    let info: DeviceInfo?

    /// design's literal `2CA3:0020` when no device info is known yet
    /// (matches the one VID:PID this app ever expects, design §1); the real
    /// value once `info` is populated, formatted the same way.
    private var usbIDText: String {
        guard let info else { return "2CA3:0020" }
        return String(format: "%04X:%04X", info.idVendor, info.idProduct)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info?.product ?? "DJI Goggles 3")
                .font(.headline)
            LabeledContent("Serial", value: info?.serial ?? "—")
            LabeledContent("USB ID", value: usbIDText)
            LabeledContent("Bus / Address", value: info.map { "\($0.bus) / \($0.address)" } ?? "—")
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceInfoCard")
    }
}

#Preview("Known device") {
    DeviceInfoCard(info: DeviceInfo(
        product: "DJI Goggles 3",
        serial: "ABC123XYZ",
        idVendor: 0x2CA3,
        idProduct: 0x0020,
        bcdDevice: 0x0100,
        bus: 20,
        address: 3
    ))
    .padding()
}

#Preview("Unknown device (claiming, before deviceChanged)") {
    DeviceInfoCard(info: nil)
        .padding()
}
#endif
