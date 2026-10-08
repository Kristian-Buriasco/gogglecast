import GogglesXPC

#if canImport(SwiftUI)
import SwiftUI

// The waiting-for-first-picture card (design §8.1), reworded in plain
// language. The goggles-side instruction is still the primary, most prominent
// element; "Ask the goggles to resend" is a secondary, de-emphasized button
// captioned as unreliable, because `requestIFrame()` does not reliably work
// and must never be presented as the expected fix. All wording lives in
// `ConnectionMessages` so it is unit-tested.
// ─────────────────────────────────────────────────────────────────────────

/// The design §8.1 waiting-for-keyframe card: verbatim copy, a live
/// "Waiting… m:ss" elapsed counter (ticking from `enteredAt`, no coordinator
/// timer needed -- `TimelineView` redraws itself), and the secondary,
/// deliberately-unreliable "Try requesting a keyframe" button.
struct WaitingForKeyframeCard: View {
    /// When this run of `.waitingForKeyframe` was entered -- from
    /// `GogglesConnectionCoordinator.waitingForKeyframeEnteredAt`.
    let enteredAt: Date
    /// Forwards to `HelperClient.requestIFrame(reply:)` via
    /// `GogglesConnectionCoordinator.requestKeyframe()`.
    let onRequestKeyframe: () -> Void
    /// Reconnects to the goggles (the Retry button). nil hides Retry.
    var onRetry: (() -> Void)?

    /// Local, view-only feedback that a tap actually happened (the XPC call
    /// itself is fire-and-forget from this view's perspective -- the helper
    /// has no reliable "it worked" reply, see `HelperService.requestIFrame`)
    /// so the secondary button doesn't feel inert. Purely cosmetic; does not
    /// change `uiState`.
    @State private var justRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ── Primary guidance: verbatim design §8.1 copy. ──
            VStack(alignment: .leading, spacing: 8) {
                Text(ConnectionMessages.waitingTitle)
                    .font(.headline)
                Text(ConnectionMessages.waitingBody)
            }
            .fixedSize(horizontal: false, vertical: true)

            // ── Live elapsed counter. ──
            TimelineView(.periodic(from: enteredAt, by: 1)) { context in
                Text(elapsedLabel(from: enteredAt, to: context.date))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("waitingForKeyframeElapsed")
            }

            Divider()

            // ── Secondary, explicitly-unreliable escape hatch. ──
            VStack(alignment: .leading, spacing: 4) {
                Button(justRequested ? ConnectionMessages.askResendSent : ConnectionMessages.askResend) {
                    justRequested = true
                    onRequestKeyframe()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        justRequested = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(justRequested)
                .accessibilityIdentifier("requestKeyframeButton")

                Text(ConnectionMessages.askResendCaveat)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            RecoveryActionsRow(onRetry: onRetry)
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("waitingForKeyframeCard")
    }

    /// "Waiting… 0:14" / "Waiting… 1:05" -- m:ss, no leading zero on
    /// minutes, matching the task brief's exact example format.
    private func elapsedLabel(from enteredAt: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(enteredAt)))
        let minutes = total / 60
        let seconds = total % 60
        return L("Waiting… %d:%02d", minutes, seconds)
    }
}

#Preview("Just entered") {
    WaitingForKeyframeCard(enteredAt: Date(), onRequestKeyframe: {})
        .padding()
}

#Preview("14s in") {
    WaitingForKeyframeCard(enteredAt: Date().addingTimeInterval(-14), onRequestKeyframe: {})
        .padding()
}
#endif
