import GogglesXPC

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// Task 3.5: the real `.waitingForKeyframe` card (design §8.1). Replaces
// Task 3.4's single-`ProgressView` placeholder in `GogglesConnectionView`.
//
// Copy is VERBATIM from design §8.1 -- do not paraphrase it (task brief,
// explicit instruction). The goggles-side physical-toggle instruction is
// the primary, most prominent element on the card; "Try requesting a
// keyframe" is a secondary, visually de-emphasized button explicitly
// captioned as unreliable. This ordering/emphasis is a REVIEWER REJECTION
// CRITERION per the task brief -- design §6/8.1 and the plan's own
// reviewer note both say `requestIFrame()` does not reliably work and must
// never be presented as the expected fix. Concretely enforced here by:
//   - the goggles-toggle instruction rendered first, at `.body`/`.headline`
//     weight, with no button chrome (it's an instruction, not an action to
//     tap in this UI -- there's nothing to tap, it's physical);
//   - the keyframe-request control rendered last, as a `.bordered` (not
//     `.borderedProminent`) `Button`, in `.secondary` foreground color, at
//     `.caption` size, with an explicit "unlikely to fix it" caption
//     directly under it.
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
                Text("Waiting for a keyframe from your goggles")
                    .font(.headline)
                Text("Video data is arriving, but the goggles only send a new keyframe when liveview sharing is restarted.")
                Text("On the goggles, open the shortcuts menu (5D button / AR dial) and toggle **Share Liveview to Mobile Device via Wi-Fi** off, then on again.")
                Text("(Ready in a moment — this is a limitation of the goggles, not of GogglesView.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
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
                Button(justRequested ? "Keyframe requested" : "Try requesting a keyframe") {
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

                Text("Unlikely to work — the goggles-side toggle above is the reliable fix.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
        return String(format: "Waiting… %d:%02d", minutes, seconds)
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
