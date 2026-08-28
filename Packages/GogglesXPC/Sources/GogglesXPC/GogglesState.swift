import Foundation

/// User-facing connection state (design §6), mirrored here as a shared
/// source of truth for the raw `Int` that crosses the XPC boundary via
/// `GogglesClientProtocol.stateChanged(_:detail:)`.
///
/// The protocol method itself is specified with a raw `state: Int`
/// parameter (design §5.5, copied verbatim into `GogglesClientProtocol`
/// below) rather than this enum directly. Two reasons the signature stays
/// `Int` rather than being changed to `GogglesState`:
///
///   1. `@objc` protocol parameter/reply-block types are restricted to
///      Objective-C-representable types. A Swift enum with no `Int`
///      raw-value `@objc` annotation isn't automatically bridgeable the
///      way plain `Int` is; making it work would require marking this
///      `@objc enum GogglesState: Int`, which is legal but changes the
///      literal method signature the design spec and brief both give
///      verbatim ("the brief doesn't ask you to change" it).
///   2. Keeping the wire type as a raw `Int` is also simply more robust
///      across the helper/app/extension boundary during active
///      development in later phases: an old client talking to a newer
///      helper that has added a state (or vice versa) degrades to an
///      unrecognized-Int case rather than an XPC decode failure.
///
/// Both sides should nonetheless use this enum internally rather than
/// hardcoding raw integers -- construct it from the wire value with
/// `GogglesState(rawValue:)` on receipt, and send `.rawValue` when calling
/// `stateChanged`.
public enum GogglesState: Int, Sendable, CaseIterable {
    /// Helper not installed or not registered.
    case noHelper = 0
    /// Helper running, no `2CA3:0020` on USB.
    case noDevice = 1
    /// Detaching/claiming IF0/IF1, RNDIS init.
    case claiming = 2
    /// Root claim or RNDIS init failed.
    case claimFailed = 3
    /// ARP for `192.168.60.2`.
    case resolving = 4
    /// Handshake sent, nothing received yet.
    case handshaking = 5
    /// Video packets arriving, no SPS+IDR yet.
    case waitingForKeyframe = 6
    /// Displaying decoded frames.
    case live = 7
    /// Was live, no packets for > 2s.
    case stalled = 8
}
