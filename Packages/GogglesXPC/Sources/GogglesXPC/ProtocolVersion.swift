import Foundation

/// The XPC protocol version this build of `GogglesXPC` implements.
///
/// `GogglesHelperProtocol.protocolVersion(reply:)` exists (design §5.5) so
/// a client can ask a *running* helper what version it speaks -- e.g. after
/// an app update installs a new helper but the old helper process hasn't
/// been replaced/relaunched yet, or vice versa. That check needs a known
/// value to compare the reply against; hardcoding `1` independently in a
/// future helper implementation (task 2.2) and a future app's
/// mismatch-check (task 3.1) would let the two silently drift out of sync
/// as this package's Swift-level API surface evolves without a
/// corresponding version bump. Defining the current value once, here,
/// makes `GogglesXPC` itself the single source of truth both sides
/// reference (`currentProtocolVersion`) instead of each hardcoding `1`.
///
/// Bump this whenever `GogglesHelperProtocol`, `GogglesClientProtocol`,
/// `DeviceInfo`, or `StreamStats` changes in a way a client should be able
/// to detect (new/removed fields or methods, changed semantics).
/// Bumped 1 -> 2 for the multi-device picker design: `GogglesHelperProtocol`
/// gained `enumerateDevices` and every per-device call
/// (`currentDeviceInfo`/`startStreaming`/`stopStreaming`/`requestIFrame`/
/// `reconnect`) gained a `deviceId` parameter instead of implicitly acting
/// on "whatever's claimed"; `GogglesClientProtocol`'s fan-out callbacks
/// (`deviceChanged`/`stateChanged`/`nalUnit`/`stats`) gained a leading
/// `deviceId` parameter too. This is a breaking wire-protocol change (every
/// method signature changed), which is exactly what
/// `currentProtocolVersion`'s doc comment says to bump for.
public let currentProtocolVersion: Int = 2
