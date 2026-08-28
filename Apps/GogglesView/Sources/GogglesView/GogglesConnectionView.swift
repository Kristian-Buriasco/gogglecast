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
