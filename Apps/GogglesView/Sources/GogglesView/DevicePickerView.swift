#if canImport(AppKit)
import SwiftUI

// Multi-device picker design item 7: the screen shown ahead of
// `GogglesConnectionView` while `DevicePickerCoordinator` is still
// resolving which device to stream. `.discovering` intentionally mirrors
// `GogglesConnectionView`'s existing `.noDevice` overlay (same icon/copy)
// so the single-device regression path looks identical to before this
// change from a user's perspective -- only `.picking` (2+ devices, mock-
// tested only tonight, no second physical unit available) is new UI.
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
        }
    }
}
#endif
