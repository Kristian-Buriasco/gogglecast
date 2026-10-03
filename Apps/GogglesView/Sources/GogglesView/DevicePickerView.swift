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
        case .selected:
            Label("Connect your Goggles 3 with USB-C", systemImage: "cable.connector")
                .foregroundStyle(.white)
                .accessibilityIdentifier("picker-discovering")

        case .discovering:
            // 0 devices, helper connected: show the diagnostic checklist.
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect your Goggles 3 with USB-C", systemImage: "cable.connector")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                SetupChecklistView(items: SetupChecklist.items(
                    registration: .init(HelperRegistration.status), reachability: .connected, devicesFound: 0))
            }
            .frame(maxWidth: 460, alignment: .leading)
            .accessibilityIdentifier("picker-discovering")

        case .picking(let candidates):
            VStack(alignment: .leading, spacing: 14) {
                // User-directed change: no more auto-select, so this
                // screen (and its heading) is now the every-time path,
                // not just the 2+-device case -- the heading adapts
                // rather than always saying "Multiple Goggles found".
                Text(candidates.count == 1 ? "Select your Goggles" : "Multiple Goggles found — choose one")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(candidates) { candidate in
                            DevicePickerCandidateRow(candidate: candidate) {
                                picker.select(candidate.id)
                            }
                        }
                    }
                }
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
                SetupChecklistView(items: SetupChecklist.items(
                    registration: .init(HelperRegistration.status),
                    reachability: reason == nil ? .disconnected : .versionMismatch, devicesFound: nil))
                    .frame(maxWidth: 460, alignment: .leading)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("picker-connectionUnavailable")
        }
    }
}

/// One selectable candidate in the `.picking` list: goggles icon, product
/// name (the "type of goggles" -- currently always "DJI Goggles 3", the
/// only VID:PID this app targets, but shown explicitly rather than
/// assumed, per user feedback -- ready to actually distinguish models the
/// day this app supports more than one), and the same Serial/USB ID/
/// Bus-Address detail `DeviceInfoCard` shows post-selection, so a user with
/// several identical-looking units can actually tell them apart.
private struct DevicePickerCandidateRow: View {
    let candidate: DevicePickerCandidate
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // "eyeglasses" rather than "visionpro" -- guaranteed present
                // across SF Symbols versions/deployment targets, where a
                // newer/rarer symbol name risks silently rendering nothing.
                Image(systemName: "eyeglasses")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.product ?? "DJI Goggles 3")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    LabeledContent("Serial", value: candidate.serial ?? "—")
                    LabeledContent("USB ID", value: candidate.usbIDText)
                    LabeledContent("Bus / Address", value: "\(candidate.bus) / \(candidate.address)")
                }
                .font(.caption)

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("picker-candidate-\(candidate.id)")
    }
}
#endif
