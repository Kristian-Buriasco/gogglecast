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
    /// Settings is genuinely usable before any device is selected --
    /// registering/re-registering the helper is exactly the thing you'd
    /// need to do *first*, before a device can even show up -- so this
    /// screen gets the same footer `GogglesConnectionView` has, not just
    /// the post-selection one. `nil` only in contexts with no real
    /// `SettingsWindowController` (mirrors `GogglesConnectionView`'s own
    /// `onOpenSettings?` optionality).
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                AppChrome.backgroundColor.ignoresSafeArea()
                content
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footerBar
        }
        .background(AppChrome.backgroundColor)
    }

    private var footerBar: some View {
        HStack(alignment: .center) {
            Button {
                onOpenSettings?()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(onOpenSettings == nil)
            .help(onOpenSettings == nil ? "Settings isn't available in this build." : "Open Settings")
            .accessibilityIdentifier("settingsButton")

            Spacer()

            Text(AppChrome.versionFooterText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("versionFooterText")
        }
        .padding([.horizontal, .bottom])
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
