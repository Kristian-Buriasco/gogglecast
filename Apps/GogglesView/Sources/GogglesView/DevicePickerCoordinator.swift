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
// UPDATED per live user feedback (hardware-verified, post-multi-device):
// the picker screen (`DevicePickerView`) always shows and always requires
// an explicit tap, even for exactly one candidate -- the original design
// auto-selected a sole candidate (matching the pre-multi-device app's
// "just plug it in, no extra step" behavior); the user asked for that
// removed after seeing it live, so `poll()` now routes any non-zero
// candidate count to `.picking`. 0 candidates still shows `.discovering`
// (visually equivalent to the existing `.noDevice` screen), polled at the
// same ~1s cadence the helper's own (pre-existing) device-retry poll uses.
// ─────────────────────────────────────────────────────────────────────────

/// Value-type snapshot of `GogglesXPC.DeviceInfo` for `@Published`/SwiftUI
/// use -- `DeviceInfo` is an `NSObject` (required for the XPC boundary,
/// see that type's doc comment) without a content-based `Equatable`
/// conformance, which `DevicePickerState`'s own `Equatable` needs.
public struct DevicePickerCandidate: Equatable, Identifiable, Sendable {
    public let id: String
    public let product: String?
    public let serial: String?
    /// Full USB identity, carried through so the picker row can show the
    /// same "type of goggles" detail (`VID:PID`, bus/address) the
    /// post-selection `DeviceInfoCard` shows -- useful the moment this app
    /// ever supports more than one goggles model/VID:PID, and honest right
    /// now about which physical port each candidate is on.
    public let idVendor: UInt16
    public let idProduct: UInt16
    public let bus: UInt8
    public let address: UInt8

    public init(id: String, product: String?, serial: String?, idVendor: UInt16, idProduct: UInt16, bus: UInt8, address: UInt8) {
        self.id = id
        self.product = product
        self.serial = serial
        self.idVendor = idVendor
        self.idProduct = idProduct
        self.bus = bus
        self.address = address
    }

    public init(_ info: DeviceInfo) {
        self.init(
            id: info.deviceId, product: info.product, serial: info.serial,
            idVendor: info.idVendor, idProduct: info.idProduct, bus: info.bus, address: info.address
        )
    }

    /// `"2CA3:0020"`-style, matching `DeviceInfoCard`'s own formatting.
    public var usbIDText: String {
        String(format: "%04X:%04X", idVendor, idProduct)
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
            default:
                // User-directed change: always show the picker screen and
                // require an explicit tap, even for exactly one candidate
                // -- no more auto-select. (Originally this case
                // auto-selected the sole candidate, matching the pre-
                // multi-device app's "just plug it in" behavior; the user
                // asked for that removed after seeing it live.)
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
