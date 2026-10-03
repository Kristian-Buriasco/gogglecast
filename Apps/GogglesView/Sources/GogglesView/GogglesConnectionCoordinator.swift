import Foundation
import GogglesXPC
#if canImport(Combine)
import Combine
#endif
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4: wires `HelperClient`'s real callback surface (Task 3.1) into
// `GogglesUIStateMachine`'s pure logic (this task, `GogglesUIState.swift`),
// and owns the two pieces that logic can't own itself because they need
// real time/timers: the local silence-watchdog clock, and the
// escalated-handshaking recovery hook. Exposed as an `ObservableObject` so
// a SwiftUI view (`GogglesConnectionView.swift`) can just `@ObservedObject`
// it.
//
// (Multi-window update: callbacks are now registered per-deviceId via
// `HelperClient.setHandlers(_:for:)`; tests drive them through the
// client's internal `handle*`/`broadcastConnectionState` routing entry
// points with synchronous delivery -- see `HelperClientTestSupport.swift`.)
//
// Test seam (task brief point 6, "unit-test the state-transition logic
// itself" + point 5, "force/verify each state ... by feeding synthetic
// events into your state-driving logic"): `HelperClient`'s four callback
// closures (`onConnectionStateChange`/`onDeviceChanged`/
// `onHelperStateChanged`/`onNALUnit`) are plain public `var`s, not a
// delegate protocol -- once `wireCallbacks()` assigns them, a test holding
// the *same* `HelperClient` instance can invoke
// `client.onHelperStateChanged?(...)` etc. directly, with no
// `NSXPCConnection`/listener/helper process involved at all, and observe
// `coordinator.uiState` update exactly as it would from a real XPC
// round trip. `GogglesUIStateTests.swift`'s coordinator-level suite does
// exactly this for all 9 states.
// ─────────────────────────────────────────────────────────────────────────

/// Drives `GogglesUIState` from a live (or test-fed) `HelperClient`.
public final class GogglesConnectionCoordinator: ObservableObject {

    @Published public private(set) var uiState: GogglesUIState = .noHelper(reason: nil)
    @Published public private(set) var deviceInfo: DeviceInfo?
    @Published public private(set) var stats: StreamStats?
    /// Goggles battery %, `nil` when unknown.
    @Published public private(set) var batteryPercent: Int?
    /// Extra observer for the latest battery value (used by `--battery-test`).
    public var onBatteryChanged: ((Int?) -> Void)?
    /// Task 3.5: when the current run of `.waitingForKeyframe` was entered --
    /// `WaitingForKeyframeCard`'s live "Waiting… m:ss" counter ticks from
    /// this via its own `TimelineView`, so no coordinator-owned repeating
    /// timer is needed for it (unlike `.handshaking`'s `elapsedSeconds`,
    /// which predates this task -- see `tick()`). `nil` until the state is
    /// reached at least once.
    @Published public private(set) var waitingForKeyframeEnteredAt: Date?

    private let client: HelperClient
    /// Multi-device picker design item 7: which device this coordinator
    /// drives. One coordinator == one device's connection lifecycle, for
    /// this coordinator's entire lifetime -- a device-selection step
    /// (`DevicePickerCoordinator`) picks the `deviceId` *before* one of
    /// these is even constructed; this type never re-targets itself to a
    /// different device. Matches the design's own explicit framing: "per-
    /// window bundles are already plain locals injected into a
    /// coordinator, not singletons" -- a future multi-window follow-up
    /// would just construct one `GogglesConnectionCoordinator` per window,
    /// each with its own `deviceId`.
    public let deviceId: String
    /// Injectable clock -- tests pass a controllable one so the 2s/5s
    /// watchdog thresholds can be exercised deterministically via `tick(at:)`
    /// rather than actually sleeping.
    private let now: () -> Date

    private var lastActivityAt: Date
    private var handshakingEnteredAt: Date?
    private var watchdogTimer: Timer?

    /// Task 3.5: passthrough for NAL data to a real decode consumer
    /// (`DecodeSession`), alongside (not instead of) this coordinator's own
    /// `handleActivitySignal()` bookkeeping. `client.onNALUnit` itself is
    /// fully owned by `wireCallbacks()` below -- a caller that also wants
    /// the raw NAL data (e.g. `main.swift`'s real end-to-end harness, which
    /// needs both this coordinator's state machine AND a `DecodeSession` to
    /// actually paint video for `.live`) sets this closure instead of
    /// touching `client.onNALUnit` directly, which would silently clobber
    /// the watchdog-activity wiring.
    public var onNALUnit: ((Data, UInt8, Bool, UInt64) -> Void)?

    /// - Parameters:
    ///   - client: the `HelperClient` to drive from. Not connected here --
    ///     callers (`main.swift`'s eventual app shell) still call
    ///     `client.connect()` themselves, same as `--test-client`/
    ///     `--live-view` already do; this type only wires callbacks.
    ///   - now: clock override for tests. Defaults to the real wall clock.
    ///   - startWatchdog: `false` in tests that drive `tick(at:)` manually
    ///     and don't want a real `Timer` also running concurrently.
    public init(client: HelperClient, deviceId: String, now: @escaping () -> Date = Date.init, startWatchdog: Bool = true) {
        self.client = client
        self.deviceId = deviceId
        self.now = now
        self.lastActivityAt = now()
        wireCallbacks()
        if startWatchdog {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            watchdogTimer = timer
        }
    }

    deinit {
        watchdogTimer?.invalidate()
        detach()
    }

    private var connectionObserverToken: HelperConnectionObserverToken?

    /// Unhooks this coordinator from the shared `HelperClient` and stops its
    /// watchdog. Idempotent. Does not stop streaming -- `GogglesSession.teardown`
    /// does that.
    public func detach() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let token = connectionObserverToken {
            client.removeConnectionStateObserver(token)
            connectionObserverToken = nil
            client.removeHandlers(for: deviceId)
        }
    }

    /// Best-effort retry action for the `claimFailed`/`noDevice`-ish "Retry"
    /// button (design §6's `claimFailed` row) -- forwards to
    /// `HelperClient.reconnectHelper`, which itself forwards to
    /// `GogglesHelperProtocol.reconnect` (full USB detach/claim/RNDIS rerun,
    /// Task 3.1/2.2).
    public func retry() {
        client.reconnectHelper(deviceId: deviceId)
    }

    /// Task 3.5: the "Reconnect" command's action -- design §8.1: "reachable
    /// at any time from a 'Reconnect' menu item, which performs a full §5.1
    /// teardown-and-reconnect (new random session id included) and then
    /// shows the [waitingForKeyframe] card." Functionally identical to
    /// `retry()` above (same `HelperClient.reconnectHelper()` ->
    /// `GogglesHelperProtocol.reconnect(reply:)` call, whose helper-side
    /// implementation already regenerates the session id per design §5.1
    /// step 5 -- nothing to add on this side), kept as a separate,
    /// separately-named entry point since the two are semantically distinct
    /// UI affordances (`claimFailed`'s error-recovery "Retry" vs. an
    /// always-available "Reconnect" command) even though today they do the
    /// same thing. `main.swift`'s temporary "Goggles > Reconnect" menu item
    /// calls this. "then shows the waitingForKeyframe card" is not
    /// special-cased here -- it falls out naturally: `reconnect()` re-runs
    /// the full connect sequence, and `handleHelperStateChanged` already
    /// drives `uiState` through `.noDevice` -> `.claiming` -> ... ->
    /// `.waitingForKeyframe` from the helper's own real `stateChanged`
    /// callbacks as it does so.
    public func reconnect() {
        client.reconnectHelper(deviceId: deviceId)
    }

    /// Task 3.5: the waitingForKeyframe card's secondary, explicitly
    /// unreliable "Try requesting a keyframe" button -- forwards to
    /// `HelperClient.requestIFrame(reply:)` -> `GogglesHelperProtocol
    /// .requestIFrame(reply:)`. Deliberately does not touch `uiState`: the
    /// helper has no reliable "it worked" signal for this (see
    /// `HelperService.requestIFrame`'s doc comment), so the only honest
    /// state transition remains the real one -- a fresh keyframe actually
    /// arriving, mapped by `mapHelperState` like any other.
    public func requestKeyframe() {
        client.requestIFrame(deviceId: deviceId)
    }

    /// The `noHelper` state's "Set up" action (design §6:
    /// `"Set up" button -> SMAppService.register()`). Routed through
    /// `HelperRegistration` (task-gui-v2) rather than constructing its own
    /// `SMAppService.daemon(plistName:)` with a re-typed literal -- see that
    /// type's doc comment for why this used to be a second (of what became
    /// three) independent copies of the same registration call.
    public func setUpHelper() throws {
        #if canImport(ServiceManagement)
        try HelperRegistration.register()
        #endif
    }

    // MARK: - Wiring

    /// Multi-window: registers through `HelperClient`'s per-device routing
    /// (keyed by `deviceId`) and an additive connection-state observer, so
    /// several coordinators -- one per open goggles window -- and the picker
    /// can share one client without clobbering each other's callbacks.
    private func wireCallbacks() {
        connectionObserverToken = client.addConnectionStateObserver { [weak self] state in
            self?.handleConnectionStateChange(state)
        }
        client.setHandlers(HelperDeviceHandlers(
            onDeviceChanged: { [weak self] info in
                self?.deviceInfo = info
            },
            onHelperStateChanged: { [weak self] raw, detail in
                self?.handleHelperStateChanged(raw, detail: detail)
            },
            onNALUnit: { [weak self] data, nalType, isParameterSet, hostTime in
                self?.handleActivitySignal()
                self?.onNALUnit?(data, nalType, isParameterSet, hostTime)
            },
            onStats: { [weak self] stats in
                self?.stats = stats
                self?.handleActivitySignal()
            },
            onBatteryChanged: { [weak self] percent in
                self?.batteryPercent = percent
                self?.onBatteryChanged?(percent)
            }
        ), for: deviceId)
    }

    private func handleConnectionStateChange(_ state: HelperClientConnectionState) {
        // Not one of the 9 device/stream states (see GogglesUIState.swift's
        // file doc comment) -- folded into `.noHelper` with a reason (or
        // `nil` for a plain not-connected-yet case), since the app
        // functionally can't use the helper either way. `noHelperReasonText`/
        // `isHelperUnavailable` (HelperClient.swift) are shared, not forked,
        // with `DevicePickerCoordinator`'s identical check (BLOCKER 2 fix,
        // multi-device picker review round 2).
        if state.isHelperUnavailable {
            uiState = .noHelper(reason: state.noHelperReasonText)
            return
        }
        // Only `.connected` can reach here (`isHelperUnavailable` is `true`
        // for every other case, and already returned above).
        do {
            // Nothing to show yet until the first `stateChanged` callback
            // lands -- `HelperService.registerConnection` sends one
            // immediately on every fresh connection (with whatever
            // `currentStateValue` already is, `.noDevice` by default), so
            // this is a brief transitional placeholder, not a dead end.
            if case .noHelper = uiState {
                uiState = .noDevice
            }
            // Task 3.7, design §9.3 scenario 5 (`sudo killall GogglesHelper`
            // while live): every reconnect (this callback fires on EVERY
            // transition into `.connected`, not just the first) gets a
            // brand new `NSXPCConnection` object on the helper side too, so
            // `HelperService`'s `streamingSubscriberIDs` (keyed by that
            // connection's own `ObjectIdentifier`) has no memory of this
            // subscriber ever having called `startStreaming` -- the old
            // registration died with the old connection. Without
            // re-calling it here, the app was observed staying wedged at
            // `.noDevice` forever after any reconnect (helper kill, or any
            // other XPC interruption) even though the daemon and hardware
            // were both fine: nothing was ever asking it to stream again.
            // `startStreaming` is documented safe to call repeatedly (an
            // already-streaming subscriber just re-registers into the same
            // fan-out set), so this is unconditional and has no special
            // case to get wrong.
            client.startStreaming(deviceId: deviceId, reply: { _, _ in })
        }
    }

    private func handleHelperStateChanged(_ raw: Int, detail: String?) {
        let mapped = GogglesUIStateMachine.mapHelperState(raw, detail: detail)
        // Only stamp a fresh `waitingForKeyframeEnteredAt` on actual entry
        // into the state, not on every repeated `stateChanged` callback the
        // helper might send while already in it -- otherwise the card's
        // elapsed counter would keep resetting to 0 instead of counting up.
        if mapped.kind == .waitingForKeyframe, uiState.kind != .waitingForKeyframe {
            waitingForKeyframeEnteredAt = now()
        }
        uiState = mapped
        if case .handshaking = mapped {
            handshakingEnteredAt = now()
        }
    }

    /// Any real inbound-data signal (a decoded NAL, or a stats snapshot --
    /// both only ever originate from an actually-running pipeline) counts
    /// as "activity" for the silence watchdog, and is also the recovery
    /// path out of a silence-escalated `.handshaking` (see
    /// `GogglesUIStateMachine.applySilenceWatchdog`'s doc comment for why
    /// the pure watchdog function alone can't do this part: once escalated
    /// past `.stalled` to `.handshaking`, `current.kind` is no longer
    /// `.live`/`.stalled`, so the watchdog's own switch leaves it alone by
    /// design -- this is the other half of that same design decision).
    private func handleActivitySignal() {
        lastActivityAt = now()
        if case .handshaking = uiState {
            uiState = .live
        }
    }

    // MARK: - Watchdog

    /// Re-evaluates the silence watchdog against `currentTime` (defaults to
    /// the coordinator's own clock). `internal`, not `private`, so
    /// `GogglesUIStateTests` can drive it directly with a fabricated time
    /// instead of waiting on the real `Timer`.
    func tick(currentTime: Date? = nil) {
        let t = currentTime ?? now()
        let elapsed = t.timeIntervalSince(lastActivityAt)
        let updated = GogglesUIStateMachine.applySilenceWatchdog(current: uiState, secondsSinceLastActivity: elapsed)
        if updated != uiState {
            uiState = updated
            if case .handshaking = updated {
                handshakingEnteredAt = t
            }
        }
        if case .handshaking(let currentElapsed) = uiState, let enteredAt = handshakingEnteredAt {
            let secs = max(0, Int(t.timeIntervalSince(enteredAt)))
            if secs != currentElapsed {
                uiState = .handshaking(elapsedSeconds: secs)
            }
        }
    }

    // MARK: - Debug/test forcing (task brief point 5: "a way to
    // force/verify each of the 9 states")

    /// Directly overrides `uiState`, bypassing every callback/watchdog
    /// above. Used by `main.swift --force-state` (manual visual
    /// verification, no live hardware needed) and available to tests that
    /// want to seed a starting state before exercising a transition.
    public func forceState(_ state: GogglesUIState) {
        uiState = state
        if case .handshaking = state {
            handshakingEnteredAt = now()
        }
        if state.kind == .waitingForKeyframe {
            waitingForKeyframeEnteredAt = now()
        }
    }
}
