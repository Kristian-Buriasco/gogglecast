import Foundation
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Multi-device picker design item 7: the device-selection step that
// precedes the existing 9-state `GogglesUIState` machine. Deliberately kept
// as its own small coordinator/state pair rather than adding cases to
// `GogglesUIState` -- that enum stays modeling exactly one device's
// connection lifecycle, per the design's explicit instruction ("design this
// as a device selection step that precedes entering the existing per-device
// state machine, rather than adding picker-related cases to the existing
// GogglesUIState enum").
//
// Regression-path behavior (0 or 1 device): polls `enumerateDevices` once
// connected, same ~1s cadence the helper's own (pre-existing) device-retry
// poll used, and auto-selects the instant exactly one candidate appears --
// no user action, matching the old singular protocol's "just plug it in"
// behavior exactly. Only shows an actual picker screen (`DevicePickerView`)
// when 2+ devices are found. NOT hardware-verified as of this writing (no
// physical Goggles 3 was connected to the machine this was written on) --
// see the task report for the honest, current verification status; this
// comment should be read as design intent, not a claim that it was
// observed working.
// ─────────────────────────────────────────────────────────────────────────

/// Value-type snapshot of `GogglesXPC.DeviceInfo` for `@Published`/SwiftUI
/// use -- `DeviceInfo` is an `NSObject` (required for the XPC boundary,
/// see that type's doc comment) without a content-based `Equatable`
/// conformance, which `DevicePickerState`'s own `Equatable` needs.
public struct DevicePickerCandidate: Equatable, Identifiable, Sendable {
    public let id: String
    public let product: String?
    public let serial: String?

    public init(id: String, product: String?, serial: String?) {
        self.id = id
        self.product = product
        self.serial = serial
    }

    public init(_ info: DeviceInfo) {
        self.init(id: info.deviceId, product: info.product, serial: info.serial)
    }
}

public enum DevicePickerState: Equatable {
    /// Connected to the helper, polling `enumerateDevices`, nothing found
    /// yet -- visually equivalent to the existing `.noDevice` screen.
    case discovering
    /// More than one candidate found; waiting for the user to choose.
    case picking([DevicePickerCandidate])
    /// A `deviceId` has been chosen (auto-selected, or by the user) --
    /// callers mount a `GogglesConnectionCoordinator` bound to it and stop
    /// consulting this coordinator's state.
    case selected(String)
    /// BLOCKER 2 fix (multi-device picker review round 2): the XPC
    /// connection to the helper is down, still connecting, or speaking an
    /// incompatible protocol version -- mirrors
    /// `GogglesUIState.noHelper(reason:)`'s exact meaning, surfaced here
    /// too since this coordinator runs BEFORE any
    /// `GogglesConnectionCoordinator` exists to show it. Without this
    /// case, `--run`'s picker phase silently showed `.discovering`'s
    /// "Connect your Goggles 3 with USB-C" for a genuinely broken
    /// connection (helper not installed, or a protocol version mismatch)
    /// -- a real regression of Task 3.1's hardware-verified loud-failure
    /// behavior. `reason` is `nil` for a plain not-yet-connected case, or
    /// the version-mismatch detail text (`HelperClientConnectionState
    /// .noHelperReasonText`) when that's the specific cause.
    case connectionUnavailable(reason: String?)
}

/// Drives `DevicePickerState` from a live `HelperClient`, ahead of any
/// `GogglesConnectionCoordinator` existing. Owns (overwrites) the client's
/// `onConnectionStateChange` closure while active; a caller that later
/// constructs a `GogglesConnectionCoordinator` on the same `client`
/// instance is expected to do so only *after* `state` reaches `.selected`
/// (that coordinator's own `init` rewires the same closure for its own
/// per-device purposes).
public final class DevicePickerCoordinator: ObservableObject {

    @Published public private(set) var state: DevicePickerState = .discovering

    private let client: HelperClient
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?

    public init(client: HelperClient, pollInterval: TimeInterval = 1.0) {
        self.client = client
        self.pollInterval = pollInterval
        client.onConnectionStateChange = { [weak self] connectionState in
            self?.handleConnectionStateChange(connectionState)
        }
    }

    /// BLOCKER 2 fix (review round 2): reacts to every connection state,
    /// not just `.connected` -- `.connecting`/`.disconnected`/
    /// `.versionMismatch` all surface as `.connectionUnavailable(reason:)`
    /// instead of being silently ignored (which previously left `state`
    /// stuck at its default `.discovering`, indistinguishable from "no
    /// device plugged in yet" for a connection that will never succeed).
    /// Uses the same `isHelperUnavailable`/`noHelperReasonText` shared
    /// logic `GogglesConnectionCoordinator` uses, not a forked copy.
    private func handleConnectionStateChange(_ connectionState: HelperClientConnectionState) {
        guard !isSelected else { return }
        if connectionState.isHelperUnavailable {
            pollTimer?.invalidate()
            pollTimer = nil
            state = .connectionUnavailable(reason: connectionState.noHelperReasonText)
            return
        }
        // `.connected`: if we were previously showing a connection
        // failure, drop back to `.discovering` before polling resumes, so
        // the screen doesn't sit on stale failure text while a fresh
        // `enumerateDevices` round trip is in flight.
        if case .connectionUnavailable = state {
            state = .discovering
        }
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func startPolling() {
        guard pollTimer == nil, !isSelected else { return }
        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var isSelected: Bool {
        if case .selected = state { return true }
        return false
    }

    private func poll() {
        guard !isSelected else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        client.enumerateDevices { [weak self] infos in
            guard let self, !self.isSelected else { return }
            switch infos.count {
            case 0:
                self.state = .discovering
            case 1:
                self.select(infos[0].deviceId)
            default:
                self.state = .picking(infos.map(DevicePickerCandidate.init))
            }
        }
    }

    /// Locks in a `deviceId` -- called automatically for the 0/1-device
    /// case, or by `DevicePickerView` when the user taps a row in the
    /// 2+-device case. Stops polling; `state` never changes again after
    /// this.
    public func select(_ deviceId: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        state = .selected(deviceId)
    }
}
