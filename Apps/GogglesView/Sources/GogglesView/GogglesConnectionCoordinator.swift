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

    private let client: HelperClient
    /// Injectable clock -- tests pass a controllable one so the 2s/5s
    /// watchdog thresholds can be exercised deterministically via `tick(at:)`
    /// rather than actually sleeping.
    private let now: () -> Date

    private var lastActivityAt: Date
    private var handshakingEnteredAt: Date?
    private var watchdogTimer: Timer?

    /// - Parameters:
    ///   - client: the `HelperClient` to drive from. Not connected here --
    ///     callers (`main.swift`'s eventual app shell) still call
    ///     `client.connect()` themselves, same as `--test-client`/
    ///     `--live-view` already do; this type only wires callbacks.
    ///   - now: clock override for tests. Defaults to the real wall clock.
    ///   - startWatchdog: `false` in tests that drive `tick(at:)` manually
    ///     and don't want a real `Timer` also running concurrently.
    public init(client: HelperClient, now: @escaping () -> Date = Date.init, startWatchdog: Bool = true) {
        self.client = client
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
    }

    /// Best-effort retry action for the `claimFailed`/`noDevice`-ish "Retry"
    /// button (design §6's `claimFailed` row) -- forwards to
    /// `HelperClient.reconnectHelper`, which itself forwards to
    /// `GogglesHelperProtocol.reconnect` (full USB detach/claim/RNDIS rerun,
    /// Task 3.1/2.2).
    public func retry() {
        client.reconnectHelper()
    }

    /// The `noHelper` state's "Set up" action (design §6:
    /// `"Set up" button -> SMAppService.register()`).
    public func setUpHelper() throws {
        #if canImport(ServiceManagement)
        try SMAppService.daemon(plistName: "com.kburiasco.gogglesview.helper.plist").register()
        #endif
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        client.onConnectionStateChange = { [weak self] state in
            self?.handleConnectionStateChange(state)
        }
        client.onDeviceChanged = { [weak self] info in
            self?.deviceInfo = info
        }
        client.onHelperStateChanged = { [weak self] raw, detail in
            self?.handleHelperStateChanged(raw, detail: detail)
        }
        client.onNALUnit = { [weak self] _, _, _, _ in
            self?.handleActivitySignal()
        }
        client.onStats = { [weak self] stats in
            self?.stats = stats
            self?.handleActivitySignal()
        }
    }

    private func handleConnectionStateChange(_ state: HelperClientConnectionState) {
        switch state {
        case .connecting, .disconnected:
            uiState = .noHelper(reason: nil)
        case .versionMismatch(let reported, let expected):
            // Not one of the 9 device/stream states (see GogglesUIState.swift's
            // file doc comment) -- folded into `.noHelper` with a reason,
            // since the app functionally can't use the helper either way.
            uiState = .noHelper(reason: "helper protocol version \(reported) does not match app's \(expected) -- reinstall/update the helper or the app")
        case .connected:
            // Nothing to show yet until the first `stateChanged` callback
            // lands -- `HelperService.registerConnection` sends one
            // immediately on every fresh connection (with whatever
            // `currentStateValue` already is, `.noDevice` by default), so
            // this is a brief transitional placeholder, not a dead end.
            if case .noHelper = uiState {
                uiState = .noDevice
            }
        }
    }

    private func handleHelperStateChanged(_ raw: Int, detail: String?) {
        let mapped = GogglesUIStateMachine.mapHelperState(raw, detail: detail)
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
    }
}
