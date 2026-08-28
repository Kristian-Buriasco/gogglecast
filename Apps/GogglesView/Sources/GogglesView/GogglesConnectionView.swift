import GogglesXPC

#if canImport(AppKit)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4: the top-level view that switches on `GogglesUIState` (design
// §6's whole table) and renders the device-info card (from `.claiming`
// onward) plus state-appropriate content. `.live` hosts Task 3.3's
// `GogglesVideoView` unchanged; `.waitingForKeyframe`'s content is
// deliberately a minimal placeholder (task brief: "Task 3.5's job to build
// in full ... a correctly-driven enum value with minimal placeholder
// content is the right scope for 3.4").
// ─────────────────────────────────────────────────────────────────────────

struct GogglesConnectionView: View {
    @ObservedObject var coordinator: GogglesConnectionCoordinator
    let session: DecodeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if coordinator.uiState.kind.showsDeviceCard {
                DeviceInfoCard(info: coordinator.deviceInfo)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .accessibilityIdentifier("state-\(coordinator.uiState.kind.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.uiState {
        case .noHelper(let reason):
            VStack(spacing: 8) {
                Text(reason ?? "The GogglesView helper isn't installed or registered.")
                    .multilineTextAlignment(.center)
                Button("Set up") {
                    try? coordinator.setUpHelper()
                }
            }

        case .noDevice:
            Label("Connect your Goggles 3 with USB-C", systemImage: "cable.connector")

        case .claiming:
            ProgressView("Claiming USB interfaces…")

        case .claimFailed(let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .multilineTextAlignment(.center)
                Button("Retry") { coordinator.retry() }
            }

        case .resolving:
            ProgressView("Resolving goggles on the USB network link…")

        case .handshaking(let elapsedSeconds):
            ProgressView("Handshaking… \(elapsedSeconds)s")

        case .waitingForKeyframe:
            // Task 3.5: the real design §8.1 card -- verbatim copy, live
            // elapsed counter, and the secondary/unreliable
            // requestIFrame() button. `enteredAt` defaults to "now" only as
            // a display-time fallback (e.g. a race on the very first
            // render before the coordinator's own timestamp lands); in
            // practice `waitingForKeyframeEnteredAt` is always set by the
            // time this case is reachable (`handleHelperStateChanged`/
            // `forceState` both set it in the same update as `uiState`
            // itself).
            WaitingForKeyframeCard(
                enteredAt: coordinator.waitingForKeyframeEnteredAt ?? Date(),
                onRequestKeyframe: { coordinator.requestKeyframe() }
            )

        case .live:
            GogglesVideoView(session: session)

        case .stalled:
            ZStack {
                GogglesVideoView(session: session)
                    .opacity(0.4)
                Text("Signal lost — reconnecting…")
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
#endif
