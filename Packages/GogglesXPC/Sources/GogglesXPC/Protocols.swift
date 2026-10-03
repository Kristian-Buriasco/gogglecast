import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.1: `GogglesHelperProtocol` / `GogglesClientProtocol` (design §5.5),
// copied verbatim from the design spec's method signatures. Both are
// declared `@objc` because they're consumed via `NSXPCConnection` in later
// tasks (2.2's helper daemon exports `GogglesHelperProtocol`, 3.1's app
// exports `GogglesClientProtocol` back to the helper for the
// `deviceChanged`/`stateChanged`/`nalUnit`/`stats` callback fan-out) --
// `NSXPCConnection.remoteObjectProxy`/`exportedInterface` both require the
// protocol passed to `NSXPCInterface(with:)` to be `@objc`.
//
// Every parameter/reply-block type below is `@objc`-compatible:
//   - `Int`, `Bool`, `UInt8`, `UInt64`, `String`, `Data` bridge to
//     Objective-C automatically.
//   - `NSError` is already an Objective-C class.
//   - `DeviceInfo?` / `StreamStats` are `NSObject` subclasses conforming to
//     `NSSecureCoding` (see DeviceInfo.swift / StreamStats.swift) -- this
//     is required for them to be usable as `@objc` protocol types at all,
//     not just for `NSSecureCoding`'s wire-safety guarantees: a plain
//     Swift struct/class can't appear in an `@objc` protocol signature.
// ─────────────────────────────────────────────────────────────────────────

/// Client -> helper. Implemented by the privileged helper daemon (task
/// 2.2+), called by the app/extension through an `NSXPCConnection`'s
/// `remoteObjectProxy`.
@objc public protocol GogglesHelperProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
    /// Multi-device picker design item 2/5: lists every currently-connected
    /// `2CA3:0020` device (via `GogglesUSB.GogglesDeviceEnumerator`, no
    /// claim), each with `DeviceInfo.deviceId` populated. The app calls
    /// this to decide whether to show a picker (more than one result) or
    /// go straight to the single-device path (exactly one result).
    func enumerateDevices(reply: @escaping ([DeviceInfo]) -> Void)
    /// `deviceId` identifies which claimed/claiming device to ask about
    /// (design item 5) -- `nil` reply if that device isn't currently known
    /// to the helper (never claimed, or already released).
    func currentDeviceInfo(deviceId: String, reply: @escaping (DeviceInfo?) -> Void)
    func startStreaming(deviceId: String, reply: @escaping (Bool, NSError?) -> Void)
    func stopStreaming(deviceId: String, reply: @escaping () -> Void)
    /// Best-effort I-frame request (design §8.1) -- no failure reporting
    /// because the helper can't guarantee the goggles honor it, only that
    /// it asked.
    func requestIFrame(deviceId: String, reply: @escaping () -> Void)
    /// Full teardown + design §5.1 rerun (USB detach/claim through RNDIS
    /// bring-up again) for this one device, not just a stream restart.
    func reconnect(deviceId: String, reply: @escaping () -> Void)
}

/// Helper -> client. Implemented by each subscriber (app window,
/// extension) and exported on its own `NSXPCConnection` so the helper can
/// call back into it -- frame delivery in particular is the helper calling
/// `nalUnit` on every subscriber's exported object (task brief context,
/// design §5.5).
///
/// Multi-device picker design item 6: every callback now leads with the
/// `deviceId` it's about, since a single connection can (in principle)
/// care about more than one device over its lifetime, and fan-out is
/// scoped per-device (`HelperService.fanOut(deviceId:)`) -- a client that
/// only ever called `startStreaming` for device A never receives a
/// callback for any other `deviceId`.
@objc public protocol GogglesClientProtocol {
    func deviceChanged(_ deviceId: String, _ info: DeviceInfo?)
    /// `state` is a `GogglesState.rawValue` (design §6) -- see
    /// `GogglesState.swift` for why the wire type stays a raw `Int`
    /// rather than the enum itself. `detail` is an optional
    /// human-readable elaboration (e.g. an error string for
    /// `.claimFailed`).
    func stateChanged(_ deviceId: String, _ state: Int, detail: String?)
    /// One H.264 NAL unit. `Data` above ~16 KB is transferred out-of-line
    /// by `NSXPCConnection` automatically, so no special chunking is
    /// needed here even at the ~20-60 KB P-frame sizes measured against
    /// real hardware (task brief context; see docs/parity-results.md).
    func nalUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64)
    func stats(_ deviceId: String, _ stats: StreamStats)
    /// Goggles battery percentage (0...100) polled over IF4 DUML, or -1
    /// when unknown (not yet read, query failing, device gone).
    func batteryChanged(_ deviceId: String, percent: Int)
}
