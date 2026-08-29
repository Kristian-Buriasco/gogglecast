#if canImport(AppKit)
import SwiftUI

// Multi-device picker design item 7: the screen shown ahead of
// `GogglesConnectionView` while `DevicePickerCoordinator` is still
// resolving which device to stream. `.discovering` intentionally mirrors
// `GogglesConnectionView`'s existing `.noDevice` overlay (same icon/copy)
// so the single-device regression path is INTENDED to look identical to
// before this change from a user's perspective -- `.picking` (2+ devices)
// is new UI. Neither case is hardware-verified as of this writing (no
// physical Goggles 3 was connected during this session) -- see the task
// report for current verification status.
struct DevicePickerView: View {
    @ObservedObject var picker: DevicePickerCoordinator

    var body: some View {
        ZStack {
            AppChrome.backgroundColor.ignoresSafeArea()
            content
                .padding()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch picker.state {
        case .discovering, .selected:
            Label("Connect your Goggles 3 with USB-C", systemImage: "cable.connector")
                .foregroundStyle(.white)
                .accessibilityIdentifier("picker-discovering")

        case .picking(let candidates):
            VStack(alignment: .leading, spacing: 12) {
                Text("Multiple Goggles found — choose one")
                    .font(.headline)
                    .foregroundStyle(.white)
                List(candidates) { candidate in
                    Button {
                        picker.select(candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.product ?? "DJI Goggles 3")
                                .foregroundStyle(.primary)
                            Text(candidate.serial.map { "S/N \($0)" } ?? candidate.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("picker-candidate-\(candidate.id)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .connectionUnavailable(let reason):
            // BLOCKER 2 fix (review round 2): mirrors
            // `GogglesConnectionView`'s existing `.noHelper` overlay
            // (including its "Set up" action) -- reused visual language,
            // not new copy, for the same underlying condition surfaced one
            // step earlier in the flow.
            VStack(spacing: 8) {
                Text(reason ?? "The GogglesView helper isn't installed or registered.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Set up") {
                    try? HelperRegistration.register()
                }
            }
            .accessibilityIdentifier("picker-connectionUnavailable")
        }
    }
}
#endif
