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
public let currentProtocolVersion: Int = 1
