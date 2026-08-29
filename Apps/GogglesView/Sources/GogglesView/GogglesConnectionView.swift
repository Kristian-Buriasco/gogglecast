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
    /// task-gui-v2: opens the real Settings window (`SettingsWindowController`,
    /// owned by `main.swift`) -- `nil` only for callers that don't have a
    /// Settings window to open (none currently; kept optional rather than
    /// forcing every future harness/test host of this view to supply one).
    var onOpenSettings: (() -> Void)?

    // ── GUI restyle task: CosmoViewer-Direct-inspired chrome ──
    // (.superpowers/sdd/plan/task-gui-restyle-brief.md, later revised by
    // task-gui-v2-brief.md). The dark background + `statusRow` + `footerBar`
    // are new; `mainContent` below is exactly Task 3.4/3.5's original
    // device-card + state-content body, unchanged, just relocated into the
    // new outer chrome layout. The original pass also had a top/bottom
    // `AppGlowStrip` ambient-glow overlay here -- removed in the v2 pass per
    // live user feedback (see `AppChrome.swift`'s file doc comment).
    var body: some View {
        ZStack(alignment: .top) {
            AppChrome.backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // task-gui-v3: this used to be `statusRow` itself (see git
                // history) -- the pill now lives in the overlay just below,
                // vertically centered on the traffic lights instead of
                // flowing in-line here. This `Color.clear` spacer keeps
                // `mainContent` starting below that same band (rather than
                // sliding up under the traffic lights now that the pill row
                // no longer occupies layout space), so nothing else in this
                // VStack's layout had to change.
                Color.clear
                    .frame(height: AppChrome.titleBarHeight)

                mainContent

                footerBar
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }

            // task-gui-v3 point 1: user feedback after seeing v2 live --
            // "move the status pill up to the same vertical level as the
            // traffic-light window buttons" (they were previously in their
            // own row below the titlebar band, not aligned with them). Drawn
            // as a ZStack(alignment: .top) overlay rather than left in the
            // VStack's normal flow specifically so it can be pinned to the
            // window's very top edge and vertically centered against
            // `AppChrome.titleBarHeight` -- the same band the real
            // traffic-light buttons occupy (`applyCustomTitleBarChrome` in
            // main.swift extends this view's content up under them via
            // `.fullSizeContentView`, so this view's top edge IS the
            // window's top edge, not offset by a real titlebar). `HStack`'s
            // default vertical alignment is `.center`, so pinning this row's
            // height to `AppChrome.titleBarHeight` centers the pill in
            // exactly the same band AppKit centers the traffic lights in,
            // without hand-tuning a top-padding number to eyeball the same
            // result (see `AppChrome.titleBarHeight`'s doc comment for where
            // that 28pt figure comes from).
            statusRow
                .padding(.horizontal, 14)
                .frame(height: AppChrome.titleBarHeight)
        }
    }

    /// Task 3.4/3.5's original body, unchanged (device-info card from
    /// `.claiming` onward, then state-appropriate content) -- this skin
    /// pass only relocates it inside the new chrome, it does not alter it.
    private var mainContent: some View {
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

    /// Task brief point 2's in-window equivalent of the reference's
    /// right-aligned grouped title-bar status items -- see `StatusPill`'s
    /// doc comment for why this is one honest pill, not a fabricated
    /// "Goggles"/"Video" pair. Reuses `MenuBarController.displayText(for:)`
    /// verbatim rather than re-deriving status copy a second time.
    private var statusRow: some View {
        HStack {
            Spacer()
            StatusPill(
                category: coordinator.uiState.kind.statusGlyphCategory,
                text: MenuBarController.displayText(for: coordinator.uiState)
            )
        }
    }

    /// Task brief point 3: a small footer with a bottom-left "Settings"
    /// affordance and a bottom-right name/version string. Originally
    /// shipped `.disabled(true)` (task-gui-restyle-report.md: a disabled
    /// button reads as more honest than a silent no-op) -- task-gui-v2 now
    /// wires it to the real `SettingsWindowController` via `onOpenSettings`,
    /// so it's enabled whenever a real handler is actually available.
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
    }

    // Fix (Task 3.5 hardware bug, post-9c31c00): `GogglesVideoView` --
    // and, critically, the `session.attach(renderer:)` call inside its
    // `makeNSView` -- must be mounted ONCE, unconditionally, for the whole
    // lifetime of this view, exactly like `main.swift --live-view` mounts
    // it before `client.connect()` is ever called. It must NOT be created
    // fresh only inside the `.live`/`.stalled` switch cases below (the
    // pre-fix behavior): `coordinator.onNALUnit`/`session.handle(...)`
    // starts processing real NAL data (including the very first
    // live-transition IDR) the instant streaming starts, regardless of
    // what's on screen, but `DecodeSession.renderer` is a `weak var` that
    // silently no-ops `enqueue(_:)` until `attach(renderer:)` has run. When
    // the video view was only created on first entry to `.live`, that
    // `makeNSView`/`attach` call raced the real first IDR -- SwiftUI's
    // render pass lands strictly after the `@Published uiState` mutation,
    // by which point the coordinator's `onNALUnit` closure (wired
    // unconditionally, independent of UI state) may have already handed
    // that IDR to a still-`nil` renderer and dropped it. Every following
    // sample was then a P-frame fed to a VideoToolbox decode session that
    // never saw a keyframe, which VideoToolbox correctly rejects every
    // single time (-12909/AVFoundationErrorDomain -11821) -- matching
    // tonight's 100%-reproducible "(1/30 consecutive)" pattern exactly
    // (each sample still *constructs* fine synchronously, resetting the
    // counter, before failing async in decode). Always hosting
    // `GogglesVideoView` here (hidden via opacity when not live/stalled)
    // attaches the renderer at initial view construction, the same timing
    // `--live-view` already uses and already hardware-verified tonight.
    @ViewBuilder
    private var content: some View {
        ZStack {
            GogglesVideoView(session: session)
                .opacity(videoOpacity)
            overlay
        }
    }

    private var videoOpacity: Double {
        switch coordinator.uiState {
        case .live: return 1
        case .stalled: return 0.4
        default: return 0
        }
    }

    @ViewBuilder
    private var overlay: some View {
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
            EmptyView()

        case .stalled:
            Text("Signal lost — reconnecting…")
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
#endif
