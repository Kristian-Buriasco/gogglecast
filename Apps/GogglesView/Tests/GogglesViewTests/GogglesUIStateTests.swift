import Testing
import Foundation
@testable import GogglesView
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4 brief, point 6 ("Unit-test the state-transition logic itself...
// this is the most valuable and most testable part of this task") + point 5
// ("Build a way to force/verify each of the 9 states... by feeding
// synthetic events into your state-driving logic").
//
// Two layers of coverage:
//   1. `GogglesUIStateMachineTests` -- the pure functions in
//      `GogglesUIState.swift`, zero XPC/timer/coordinator involved.
//   2. `GogglesConnectionCoordinatorTests` -- the real
//      `GogglesConnectionCoordinator` object a SwiftUI view would actually
//      consume, driven by calling the exact closures it assigned onto a
//      real (never-`connect()`ed) `HelperClient` instance -- i.e. the same
//      seam a genuine XPC callback would use, with no fake/mock XPC layer
//      needed at all. Every one of the 9 `GogglesUIStateKind` cases is
//      reached this way at least once, satisfying the exit criterion
//      ("every state is reachable via some real code path").
// ─────────────────────────────────────────────────────────────────────────

@Suite("GogglesUIStateMachine.mapHelperState")
struct GogglesUIStateMachineMappingTests {

    @Test("every GogglesXPC.GogglesState case maps to the matching UI kind", arguments: GogglesXPC.GogglesState.allCases)
    func mapsEveryHelperStateToMatchingKind(state: GogglesXPC.GogglesState) {
        // Case names are identical strings by design (both copied verbatim
        // from design §6) -- `String(describing:)` on the raw-Int-backed
        // `GogglesState` yields exactly the case identifier.
        let mapped = GogglesUIStateMachine.mapHelperState(state.rawValue, detail: nil)
        #expect(mapped.kind.rawValue == String(describing: state))
    }

    @Test("unrecognized raw state value falls back to noDevice, not a crash")
    func unrecognizedRawValueFallsBackToNoDevice() {
        let mapped = GogglesUIStateMachine.mapHelperState(999, detail: "whatever")
        #expect(mapped == .noDevice)
    }

    @Test("claimFailed with nil detail defaults to the interface-claim diagnostic")
    func claimFailedNilDetailDefaultsToInterfaceClaim() {
        let mapped = GogglesUIStateMachine.mapHelperState(GogglesXPC.GogglesState.claimFailed.rawValue, detail: nil)
        #expect(mapped == .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed))
    }

    @Test("claimFailed with an RNDISTransportError-flavored detail -> interface-claim diagnostic")
    func claimFailedRNDISDetailUsesInterfaceClaimDiagnostic() {
        let detail = "The operation couldn’t be completed. (GogglesUSB.RNDISTransport.RNDISTransportError error 1.)"
        let mapped = GogglesUIStateMachine.mapHelperState(GogglesXPC.GogglesState.claimFailed.rawValue, detail: detail)
        #expect(mapped == .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed))
    }

    @Test("claimFailed with an ARPResolverError-flavored detail -> ARP-timeout diagnostic")
    func claimFailedARPDetailUsesARPTimeoutDiagnostic() {
        let detail = "The operation couldn’t be completed. (GogglesUSB.ARPResolver.ARPResolverError error 0.)"
        let mapped = GogglesUIStateMachine.mapHelperState(GogglesXPC.GogglesState.claimFailed.rawValue, detail: detail)
        #expect(mapped == .claimFailed(reason: GogglesDiagnostics.arpTimeout))
    }

    @Test("the two claimFailed diagnostics are distinct and each contains its design-mandated content")
    func diagnosticStringsAreDistinctAndContainRequiredContent() {
        #expect(GogglesDiagnostics.interfaceClaimFailed != GogglesDiagnostics.arpTimeout)
        // design §8.3: the network-adapter/replug workaround must be IN the claimFailed text, in plain words.
        #expect(GogglesDiagnostics.interfaceClaimFailed.contains("System Settings > Network"))
        #expect(GogglesDiagnostics.interfaceClaimFailed.contains("unplug and replug"))
        #expect(GogglesDiagnostics.interfaceClaimFailed.hasPrefix("Couldn't take control of the goggles."))
        #expect(GogglesDiagnostics.arpTimeout == "The goggles didn't respond. Turn them off and on, check OTG is enabled, then Retry.")
        // Technical wording stays available for logs and Diagnostics.
        #expect(GogglesDiagnostics.interfaceClaimFailedTechnical.contains("en*"))
        #expect(GogglesDiagnostics.arpTimeoutTechnical.contains("USB network link"))
    }
}

@Suite("GogglesUIStateMachine.applySilenceWatchdog")
struct GogglesUIStateMachineWatchdogTests {

    @Test("live, under 2s silence -> stays live")
    func liveUnder2sStaysLive() {
        #expect(GogglesUIStateMachine.applySilenceWatchdog(current: .live, secondsSinceLastActivity: 1.9) == .live)
    }

    @Test("live, at/over 2s but under 5s silence -> stalled")
    func liveAt2sBecomesStalled() {
        #expect(GogglesUIStateMachine.applySilenceWatchdog(current: .live, secondsSinceLastActivity: 2.0) == .stalled)
        #expect(GogglesUIStateMachine.applySilenceWatchdog(current: .live, secondsSinceLastActivity: 4.9) == .stalled)
    }

    @Test("live, at/over 5s silence -> handshaking, NOT waitingForKeyframe (design's explicit transition note)")
    func liveAt5sEscalatesToHandshaking() {
        let result = GogglesUIStateMachine.applySilenceWatchdog(current: .live, secondsSinceLastActivity: 5.0)
        #expect(result.kind == .handshaking)
        #expect(result != .waitingForKeyframe)
    }

    @Test("stalled, silence continues past 5s total -> escalates to handshaking")
    func stalledContinuingPast5sEscalates() {
        let result = GogglesUIStateMachine.applySilenceWatchdog(current: .stalled, secondsSinceLastActivity: 6.0)
        #expect(result.kind == .handshaking)
    }

    @Test("stalled, activity resumes under 2s -> recovers to live")
    func stalledRecoversToLiveOnFreshActivity() {
        #expect(GogglesUIStateMachine.applySilenceWatchdog(current: .stalled, secondsSinceLastActivity: 0.1) == .live)
    }

    @Test("non-live/stalled states are never touched by the watchdog, regardless of elapsed silence")
    func nonLiveStatesAreUntouched() {
        let untouchable: [GogglesUIState] = [
            .noHelper(reason: nil), .noDevice, .claiming,
            .claimFailed(reason: "x"), .resolving,
            .handshaking(elapsedSeconds: 0), .waitingForKeyframe
        ]
        for state in untouchable {
            #expect(GogglesUIStateMachine.applySilenceWatchdog(current: state, secondsSinceLastActivity: 999) == state)
        }
    }
}

// MARK: - Coordinator-level: real object, synthetic events, no XPC

/// Advances a fake clock the coordinator is constructed with, so the 2s/5s
/// watchdog thresholds are exercised deterministically via `tick()` instead
/// of sleeping in real time.
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current.addTimeInterval(seconds) }
}

@Suite("GogglesConnectionCoordinator (real object, synthetic HelperClient callbacks)")
struct GogglesConnectionCoordinatorTests {

    private func makeCoordinator() -> (HelperClient, GogglesConnectionCoordinator, TestClock) {
        let client = HelperClient() // never connect()ed -- no real XPC involved
        let clock = TestClock()
        let coordinator = GogglesConnectionCoordinator(client: client, deviceId: "test-device", now: clock.now, startWatchdog: false)
        return (client, coordinator, clock)
    }

    @Test("initial state, before any callback, is noHelper")
    func initialStateIsNoHelper() {
        let (_, coordinator, _) = makeCoordinator()
        #expect(coordinator.uiState == .noHelper(reason: nil))
    }

    @Test("connectionState .disconnected/.connecting -> noHelper")
    func disconnectedAndConnectingMapToNoHelper() {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.connecting)
        #expect(coordinator.uiState.kind == .noHelper)
        client.sendConnectionState(.disconnected)
        #expect(coordinator.uiState.kind == .noHelper)
    }

    @Test("connectionState .versionMismatch -> noHelper with a reason mentioning the versions")
    func versionMismatchMapsToNoHelperWithReason() {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.versionMismatch(reported: 1, expected: 2))
        guard case .noHelper(let reason) = coordinator.uiState else {
            Issue.record("expected .noHelper, got \(coordinator.uiState)")
            return
        }
        #expect(reason?.contains("1") == true)
        #expect(reason?.contains("2") == true)
    }

    @Test("connectionState .connected with no prior stateChanged -> noDevice")
    func connectedWithoutStateChangedYetIsNoDevice() {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.connected)
        #expect(coordinator.uiState == .noDevice)
    }

    @Test("all 7 non-watchdog helper-reported states are reachable via onHelperStateChanged", arguments: [
        GogglesXPC.GogglesState.noDevice,
        .claiming,
        .resolving,
        .handshaking,
        .waitingForKeyframe,
        .live,
        .stalled
    ])
    func helperReportedStatesAreReachable(state: GogglesXPC.GogglesState) {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", state.rawValue, nil)
        #expect(coordinator.uiState.kind.rawValue == String(describing: state))
    }

    @Test("claimFailed is reachable via onHelperStateChanged, with the ARP-vs-interface distinction preserved")
    func claimFailedReachableWithCorrectDiagnostic() {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.claimFailed.rawValue, "...ARPResolverError...")
        #expect(coordinator.uiState == .claimFailed(reason: GogglesDiagnostics.arpTimeout))

        client.sendHelperState("test-device", GogglesXPC.GogglesState.claimFailed.rawValue, "...RNDISTransportError...")
        #expect(coordinator.uiState == .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed))
    }

    @Test("waitingForKeyframeEnteredAt is stamped on entry and does not reset on repeated stateChanged callbacks in the same state")
    func waitingForKeyframeEnteredAtStampedOnceOnEntry() {
        let (client, coordinator, clock) = makeCoordinator()
        #expect(coordinator.waitingForKeyframeEnteredAt == nil)

        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.waitingForKeyframe.rawValue, nil)
        let firstStamp = coordinator.waitingForKeyframeEnteredAt
        #expect(firstStamp == clock.now())

        // A repeated stateChanged callback for the SAME state (plausible if
        // the helper resends it) must not reset the elapsed counter's
        // starting point.
        clock.advance(3.0)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.waitingForKeyframe.rawValue, nil)
        #expect(coordinator.waitingForKeyframeEnteredAt == firstStamp)

        // Leaving and re-entering the state DOES get a fresh stamp.
        clock.advance(1.0)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        clock.advance(1.0)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.waitingForKeyframe.rawValue, nil)
        #expect(coordinator.waitingForKeyframeEnteredAt == clock.now())
        #expect(coordinator.waitingForKeyframeEnteredAt != firstStamp)
    }

    @Test("forceState(.waitingForKeyframe) also stamps waitingForKeyframeEnteredAt (used by --force-state)")
    func forceStateStampsWaitingForKeyframeEnteredAt() {
        let (_, coordinator, clock) = makeCoordinator()
        coordinator.forceState(.waitingForKeyframe)
        #expect(coordinator.waitingForKeyframeEnteredAt == clock.now())
    }

    @Test("requestKeyframe() forwards to the helper without touching uiState (no reliable success signal exists)")
    func requestKeyframeDoesNotChangeState() {
        let (client, coordinator, _) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.waitingForKeyframe.rawValue, nil)
        // Never connect()ed, so this is a no-op XPC call (remoteHelperProxy()
        // is nil) -- the point of this test is only that requestKeyframe()
        // exists, is callable, and is not presented/wired as something that
        // itself resolves the state (task brief's reviewer-rejection
        // criterion: requestIFrame must never look like the fix).
        coordinator.requestKeyframe()
        #expect(coordinator.uiState == .waitingForKeyframe)
    }

    @Test("reconnect() is available as a standalone command distinct from retry(), forwarding the same way")
    func reconnectIsCallable() {
        let (_, coordinator, _) = makeCoordinator()
        // Never connect()ed -- remoteHelperProxy() is nil, so this is a
        // no-op XPC call. Exercises that the method exists and doesn't
        // crash/misbehave when called with no live connection (e.g. a user
        // hitting "Reconnect" before any device was ever seen).
        coordinator.reconnect()
    }

    @Test("live -> 2.5s silence -> stalled (app-side watchdog, driven by tick, not helper's own cascade)")
    func liveEscalatesToStalledAfter2sOfSilence() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        #expect(coordinator.uiState == .live)

        clock.advance(2.5)
        coordinator.tick()
        #expect(coordinator.uiState == .stalled)
    }

    @Test("live -> 5.5s total silence -> handshaking (not waitingForKeyframe), with a live elapsedSeconds counter")
    func liveEscalatesToHandshakingAfter5sOfSilence() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)

        clock.advance(2.5)
        coordinator.tick()
        #expect(coordinator.uiState == .stalled)

        clock.advance(3.0) // total silence now 5.5s
        coordinator.tick()
        #expect(coordinator.uiState.kind == .handshaking)

        clock.advance(4.0)
        coordinator.tick()
        guard case .handshaking(let elapsedSeconds) = coordinator.uiState else {
            Issue.record("expected .handshaking, got \(coordinator.uiState)")
            return
        }
        #expect(elapsedSeconds == 4)
    }

    @Test("recovering from a silence-escalated handshaking: fresh NAL data -> live directly (helper never re-fires pipelineDidStart)")
    func nalArrivalRecoversFromEscalatedHandshaking() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)

        clock.advance(6.0)
        coordinator.tick()
        #expect(coordinator.uiState.kind == .handshaking)

        client.sendNAL("test-device", Data([0, 0, 0, 1, 0x65]), 5, false, 0)
        #expect(coordinator.uiState == .live)
    }

    private let sampleStats = StreamStats(fps: 30, bitrateKbps: 4000, drops: 0, cumulativeFrames: 100, cumulativeBytes: 100_000, cumulativeDrops: 0)

    @Test("stats callbacks do NOT count as activity: the helper sends them every second even with no video")
    func statsCallbackIsNotActivity() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)

        clock.advance(1.9)
        client.sendStats("test-device", sampleStats)
        clock.advance(1.9) // 3.8s since the last real activity, stats in between
        coordinator.tick()
        #expect(coordinator.uiState == .stalled)
        client.sendStats("test-device", sampleStats)
        clock.advance(1.9) // 5.7s total
        coordinator.tick()
        #expect(coordinator.uiState.kind == .handshaking)
    }

    @Test("stats never flip a silence-escalated handshaking back to live; only real video does")
    func statsDoNotFlipHandshakingToLive() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        clock.advance(6)
        coordinator.tick()
        #expect(coordinator.uiState.kind == .handshaking)

        for _ in 0..<5 {
            clock.advance(1)
            client.sendStats("test-device", sampleStats)
            coordinator.tick()
            #expect(coordinator.uiState.kind == .handshaking)
        }
        client.sendNAL("test-device", Data([0, 0, 0, 1, 0x65]), 5, false, 0)
        #expect(coordinator.uiState == .live)
    }

    @Test("a lone parameter set resets the silence clock but does not claim live video")
    func parameterSetIsActivityButNotLive() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        clock.advance(6)
        coordinator.tick()
        #expect(coordinator.uiState.kind == .handshaking)
        client.sendNAL("test-device", Data([0, 0, 0, 1, 0x67]), 7, true, 0)
        #expect(coordinator.uiState.kind == .handshaking)
    }

    @Test("helper reporting live restarts the silence clock")
    func helperLiveResetsSilenceClock() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.handshaking.rawValue, nil)
        clock.advance(30)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        coordinator.tick()
        #expect(coordinator.uiState == .live)
    }

    @Test("decoder waiting for a keyframe shows the waiting card while the helper says live")
    func decoderWaitingOverridesLiveDisplay() {
        let (client, coordinator, clock) = makeCoordinator()
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        #expect(coordinator.displayState == .live)
        coordinator.setDecoderWaitingForKeyframe(true)
        #expect(coordinator.displayState == .waitingForKeyframe)
        #expect(coordinator.uiState == .live)
        #expect(coordinator.waitingForKeyframeEnteredAt == clock.now())
        coordinator.setDecoderWaitingForKeyframe(false)
        #expect(coordinator.displayState == .live)
    }

    @Test("stuck decoder: asks for a keyframe, then reconnects after 3s")
    func stuckDecoderRequestsThenReconnects() {
        let (client, coordinator, clock) = makeCoordinator()
        var actions: [KeyframeRecoveryPolicy.Action] = []
        coordinator.onRecoveryAction = { actions.append($0) }
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.live.rawValue, nil)
        coordinator.setDecoderWaitingForKeyframe(true)
        coordinator.tick()
        #expect(actions == [.requestKeyframe])
        for _ in 0..<12 {
            clock.advance(0.25)
            client.sendNAL("test-device", Data([0, 0, 0, 1, 0x41]), 1, false, 0)
            coordinator.tick()
        }
        #expect(actions.contains(.reconnect))
    }

    @Test("a waiting decoder does not trigger recovery while the helper is not live")
    func noRecoveryWithoutLive() {
        let (client, coordinator, clock) = makeCoordinator()
        var actions: [KeyframeRecoveryPolicy.Action] = []
        coordinator.onRecoveryAction = { actions.append($0) }
        client.sendConnectionState(.connected)
        client.sendHelperState("test-device", GogglesXPC.GogglesState.noDevice.rawValue, nil)
        coordinator.setDecoderWaitingForKeyframe(true)
        for _ in 0..<40 { clock.advance(0.25); coordinator.tick() }
        #expect(actions.isEmpty)
    }

    @Test("forceState reaches every one of the 9 kinds directly, for manual/--force-state visual verification")
    func forceStateReachesEveryKind() {
        let (_, coordinator, _) = makeCoordinator()
        let samples: [GogglesUIState] = [
            .noHelper(reason: nil), .noDevice, .claiming,
            .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed),
            .resolving, .handshaking(elapsedSeconds: 3),
            .waitingForKeyframe, .live, .stalled
        ]
        #expect(Set(samples.map(\.kind)) == Set(GogglesUIStateKind.allCases))
        for sample in samples {
            coordinator.forceState(sample)
            #expect(coordinator.uiState == sample)
        }
    }

    @Test("device card visibility matches design §6: hidden for noHelper/noDevice, shown claiming onward")
    func deviceCardVisibilityMatchesDesign() {
        #expect(GogglesUIStateKind.noHelper.showsDeviceCard == false)
        #expect(GogglesUIStateKind.noDevice.showsDeviceCard == false)
        for kind: GogglesUIStateKind in [.claiming, .claimFailed, .resolving, .handshaking, .waitingForKeyframe, .live, .stalled] {
            #expect(kind.showsDeviceCard == true)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Task 3.6: the menu bar's three-way glyph category. Pure/AppKit-free (see
// `GogglesStatusGlyphCategory`'s doc comment) -- exercises the brief's own
// minimum bar directly: "should visually distinguish at minimum:
// disconnected/error states, connecting/waiting states, and live."
// ─────────────────────────────────────────────────────────────────────────
@Suite("GogglesUIStateKind.statusGlyphCategory (Task 3.6 menu bar glyph)")
struct StatusGlyphCategoryTests {

    @Test("every kind maps to exactly one of the three categories, all three are used")
    func everyKindMapsToACategory() {
        let categories = Set(GogglesUIStateKind.allCases.map(\.statusGlyphCategory))
        #expect(categories == Set<GogglesStatusGlyphCategory>([.error, .waiting, .live]))
    }

    @Test("disconnected/hard-failure states map to .error")
    func errorStates() {
        for kind: GogglesUIStateKind in [.noHelper, .noDevice, .claimFailed] {
            #expect(kind.statusGlyphCategory == .error)
        }
    }

    @Test("connecting/degraded states map to .waiting")
    func waitingStates() {
        for kind: GogglesUIStateKind in [.claiming, .resolving, .handshaking, .waitingForKeyframe, .stalled] {
            #expect(kind.statusGlyphCategory == .waiting)
        }
    }

    @Test(".live maps to .live")
    func liveState() {
        #expect(GogglesUIStateKind.live.statusGlyphCategory == .live)
    }
}

#if canImport(AppKit)
import AppKit

// ─────────────────────────────────────────────────────────────────────────
// Task 3.6: `MenuBarController`'s two static, side-effect-free helpers --
// display text and glyph image selection -- are exercised directly here
// without constructing a real `NSStatusItem`/menu (which needs a running
// `NSApplication`/main run loop this test target doesn't provide). This
// covers the actual per-state content, leaving "does a real NSStatusItem
// show up and update live" to the manual `--force-state`/default-launch
// verification described in the task report.
// ─────────────────────────────────────────────────────────────────────────
@Suite("MenuBarController static helpers (Task 3.6)")
struct MenuBarControllerTests {

    @Test("displayText is plain-language and non-empty for every kind")
    func displayTextIsPopulated() {
        #expect(MenuBarController.displayText(for: .noHelper(reason: nil)) == "Background service not set up")
        #expect(MenuBarController.displayText(for: .noDevice) == "No goggles connected")
        #expect(MenuBarController.displayText(for: .claiming) == "Connecting…")
        #expect(MenuBarController.displayText(for: .resolving) == "Connecting…")
        #expect(MenuBarController.displayText(for: .handshaking(elapsedSeconds: 4)) == "Connecting…")
        #expect(MenuBarController.displayText(for: .claimFailed(reason: "x")) == "Can't connect, open GogglesView")
        #expect(MenuBarController.displayText(for: .waitingForKeyframe) == "Waiting for video, check goggles live view")
        #expect(MenuBarController.displayText(for: .live) == "Live")
        #expect(MenuBarController.displayText(for: .stalled) == "No video, reconnecting…")
    }

    @Test("noHelper with a version-mismatch reason still shows the short plain status")
    func noHelperReasonNotShownInMenu() {
        let reason = "helper protocol version 2 does not match app's 3 -- reinstall/update the helper or the app"
        #expect(MenuBarController.displayText(for: .noHelper(reason: reason)) == "Background service not set up")
    }

    @Test("live with stats appends resolution and real fps, not a placeholder")
    func liveWithStatsShowsFpsAndResolution() {
        let stats = StreamStats(fps: 56, bitrateKbps: 8200, drops: 0, cumulativeFrames: 1000, cumulativeBytes: 1_000_000, cumulativeDrops: 0)
        #expect(MenuBarController.displayText(for: .live, stats: stats, resolution: "1920x1080") == "Live · 1920x1080 · 56fps")
        #expect(MenuBarController.displayText(for: .live, stats: stats) == "Live · 56fps")
    }

    @Test("live with no stats yet omits the suffix rather than showing a stale/zero placeholder")
    func liveWithNoStatsOmitsSuffix() {
        #expect(MenuBarController.displayText(for: .live, stats: nil) == "Live")
    }

    @Test("glyphImage returns a non-nil image for every kind")
    func glyphImageAlwaysProducesAnImage() {
        for kind in GogglesUIStateKind.allCases {
            #expect(MenuBarController.glyphImage(for: kind) != nil)
        }
    }
}
#endif
