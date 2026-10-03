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
    @ObservedObject var session: DecodeSession
    /// task-gui-v2: opens the real Settings window (`SettingsWindowController`,
    /// owned by `main.swift`) -- `nil` only for callers that don't have a
    /// Settings window to open (none currently; kept optional rather than
    /// forcing every future harness/test host of this view to supply one).
    var onOpenSettings: (() -> Void)?
    /// Returns to the goggles picker (stops streaming); nil hides the button.
    var onBack: (() -> Void)?
    /// User feedback (round 3): the previous fixed `AppChrome.titleBarHeight`-
    /// based centering did not actually line up with the real traffic
    /// lights on screen. `main.swift` now measures the real live window
    /// (`AppChrome.measuredPillBandHeight(for:)`) once, after
    /// `applyCustomTitleBarChrome` has been applied, and passes the result
    /// here -- falls back to the fixed constant for previews/tests/harnesses
    /// that don't have a real on-screen window to measure.
    var pillBandHeight: CGFloat = AppChrome.titleBarHeight
    @StateObject private var recorder = Recorder()

    private var isLive: Bool {
        if case .live = coordinator.uiState { return true }
        return false
    }

    private var resolutionText: String? {
        session.dimensions.map { "\($0.width)x\($0.height)" }
    }

    @State private var screenshotNote: String?

    private func takeScreenshot() {
        guard let frame = session.copyDisplayedFrame() else { screenshotNote = "No frame yet"; return }
        do {
            let url = try Screenshot.save(frame)
            screenshotNote = "Saved \(url.lastPathComponent)"
        } catch {
            screenshotNote = "Screenshot failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { screenshotNote = nil }
    }

    private var recordControl: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                Text(Self.formatElapsed(recorder.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }
            if let err = recorder.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Button { RecordingPrefs.openFolder() } label: {
                Image(systemName: "folder").foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the recordings folder")
            .accessibilityIdentifier("openRecordingsButton")
            GalleryButton()
            FreezeControl()
            DataCollectControl(session: session, batteryPercent: coordinator.batteryPercent)
            ReplayControl(session: session)
            NetworkStreamControl(session: session)
            if let note = screenshotNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { takeScreenshot() } label: {
                Image(systemName: "camera").foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isLive)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Save a screenshot to ~/Pictures/GogglesView (⇧⌘S)")
            .accessibilityIdentifier("screenshotButton")
            MarkerControl(recorder: recorder)
            Button {
                recorder.isRecording ? stopRecording(wait: false) : startRecording()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isLive && !recorder.isRecording)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help(recorder.isRecording ? "Stop recording (⇧⌘R)" : "Record to ~/Movies/GogglesView (⇧⌘R)")
            .accessibilityIdentifier("recordButton")
        }
        .onChange(of: isLive) { live in
            if live && RecordingPrefs.autoStart && !recorder.isRecording { startRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stopRecording(wait: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gogglesToggleRecording)) { _ in
            if recorder.isRecording { stopRecording(wait: false) } else if isLive { startRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gogglesScreenshot)) { _ in
            if isLive { takeScreenshot() }
        }
    }

    private func startRecording() {
        session.addConsumer(recorder)
        do { try recorder.start() } catch { session.removeConsumer(recorder) }
    }

    private func stopRecording(wait: Bool) {
        guard recorder.isRecording else { return }
        session.removeConsumer(recorder)
        let sem = DispatchSemaphore(value: 0)
        recorder.stop { _ in sem.signal() }
        // On quit, block briefly so the .mov is finalized before exit.
        if wait { _ = sem.wait(timeout: .now() + 3) }
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // ── GUI restyle task: CosmoViewer-Direct-inspired chrome ──
    // (.superpowers/sdd/plan/task-gui-restyle-brief.md, later revised by
    // task-gui-v2-brief.md). The dark background + `statusRow` + `footerBar`
    // are new; `mainContent` below is exactly Task 3.4/3.5's original
    // device-card + state-content body, unchanged, just relocated into the
    // new outer chrome layout. The original pass also had a top/bottom
    // `AppGlowStrip` ambient-glow overlay here -- removed in the v2 pass per
    // live user feedback (see `AppChrome.swift`'s file doc comment).
    var body: some View {
        // ROOT CAUSE FOUND (Opus research, empirically proven): `.fullSizeContentView`
        // insets ALL SwiftUI content by the title bar height (32pt) via the
        // safe area -- `.ignoresSafeArea()` was previously attached only to
        // the background `Color`, not this whole ZStack, so every sibling
        // (including `topIdentityRow` below) stayed laid out INSIDE that
        // 32pt inset. Its `.frame(height: pillBandHeight)` band therefore
        // started at 32pt from the window top (not 0), landing its centered
        // content at 32+16=48pt -- exactly the 32pt-too-low offset seen in
        // every screenshot across four rounds of (correct, but irrelevant)
        // measurement debugging. Moving `.ignoresSafeArea()` here, to the
        // whole ZStack, makes ALL content (including this view's top edge)
        // span the true window top, matching what `pillBandHeight`'s
        // measurement always correctly assumed.
        ZStack(alignment: .top) {
            AppChrome.backgroundColor

            VStack(spacing: 0) {
                // The top row (compact device identity + status pill) is
                // drawn as an overlay just below, pinned to the window's
                // very top edge and vertically centered against the real
                // measured traffic-light position -- this spacer just
                // reserves that same band's height in the normal layout
                // flow so `mainContent` starts below it instead of sliding
                // up underneath.
                Color.clear
                    .frame(height: pillBandHeight)

                mainContent

                footerBar
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }

            // User feedback (round 3): device identity (name, serial, a
            // small USB mention) moved from a separate full-width card
            // below into THIS same top row, alongside the status pill --
            // "at the same level of the live bubble card" -- rather than
            // occupying its own block in `mainContent`. Pinned to the
            // window's very top edge (`ZStack(alignment: .top)`) and
            // vertically centered within `pillBandHeight`, the REAL
            // measured traffic-light band (`main.swift`,
            // `AppChrome.measuredPillBandHeight(for:)`), not an assumed
            // constant -- `applyCustomTitleBarChrome` extends this view's
            // content up under the (transparent) title bar via
            // `.fullSizeContentView`, so this view's top edge IS the
            // window's top edge.
            topIdentityRow
                // 78pt leading clearance -- the exact x-offset AppKit
                // itself uses for a `.leading` `NSTitlebarAccessoryViewController`
                // (verified empirically: traffic lights occupy roughly
                // x=7...70, AppKit's own leading-accessory placement starts
                // its content at x=78), not a guessed number -- avoids the
                // device-identity text overlapping the traffic lights.
                .padding(.leading, 78)
                .padding(.trailing, 14)
                .frame(height: pillBandHeight)
        }
        .ignoresSafeArea()
    }

    /// Task 3.4/3.5's original body, minus the device-info card (moved to
    /// `topIdentityRow`) -- state-appropriate content only now.
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .accessibilityIdentifier("state-\(coordinator.uiState.kind.rawValue)")
    }

    /// The window's top row: compact device identity (left) + status pill
    /// (right), both vertically centered against the real traffic-light
    /// position. Device identity only shows from `.claiming` onward
    /// (`GogglesUIStateKind.showsDeviceCard`, unchanged threshold from the
    /// old standalone card), same one honest pill as before (see
    /// `StatusPill`'s doc comment for why this isn't a fabricated
    /// "Goggles"/"Video" pair) reusing `MenuBarController.displayText(for:)`.
    private var topIdentityRow: some View {
        HStack(spacing: 10) {
            if coordinator.uiState.kind.showsDeviceCard {
                CompactDeviceIdentity(info: coordinator.deviceInfo)
            }
            Spacer(minLength: 8)
            StatusPill(
                category: coordinator.uiState.kind.statusGlyphCategory,
                text: MenuBarController.displayText(for: coordinator.uiState, stats: coordinator.stats, resolution: resolutionText)
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
            if let onBack {
                Button(action: onBack) {
                    Label("Devices", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to the goggles picker")
                .accessibilityIdentifier("backButton")
            }
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

            recordControl
                .padding(.trailing, 10)

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
            OSDOverlay(stats: coordinator.stats, resolution: resolutionText, latencyMs: session.latencyMs,
                       batteryPercent: coordinator.batteryPercent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
