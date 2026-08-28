import Foundation
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 3.4: the nine-state, app-facing UI state machine (design §6).
//
// Relationship to `GogglesXPC.GogglesState` (checked before writing any of
// this -- see `GogglesState.swift`'s doc comment, which is copied
// near-verbatim from design §6 and lists the exact same 9 cases with the
// exact same meanings):
//
//   - For everything *except* the live/stalled/handshaking-by-silence zone,
//     this file's `GogglesUIStateMachine.mapHelperState` is a near-direct
//     1:1 reuse of `GogglesXPC.GogglesState` -- the helper already computes
//     `.noDevice`/`.claiming`/`.claimFailed`/`.resolving`/`.handshaking`/
//     `.waitingForKeyframe` correctly (`HelperService.swift`, already
//     reviewed clean in Task 2.2/3.3) and there is no reason to
//     independently re-derive that on the app side -- that would be a
//     second, parallel, harder-to-keep-in-sync state machine for no
//     benefit. Reuse, not reinvention, per the task brief's own framing.
//   - `resolving` is declared in `GogglesXPC.GogglesState` but is, as of
//     this task, never actually emitted by `HelperService` (ARP resolution
//     happens synchronously inside `RNDISTransport.init`, with no
//     intermediate state report -- confirmed by reading
//     `HelperService.beginStreaming` and `RNDISTransport.init`). That's a
//     pre-existing gap in already-reviewed code, out of this task's scope
//     to fix; `mapHelperState` still handles raw value 4 correctly (it's
//     wired, tested, and reachable the instant a future helper change
//     starts sending it), and this task's own verification forces it
//     directly (see `GogglesUIStateTests`) since no real code path
//     currently produces it.
//   - `noHelper` is deliberately NOT part of `mapHelperState`'s useful
//     range: `GogglesXPC.GogglesState.noHelper`'s own doc comment says
//     "Helper not installed or not registered", which is a fact about the
//     XPC *connection* layer (`HelperClientConnectionState`,
//     `HelperClient.swift`, Task 3.1), not something the helper daemon
//     could ever report about itself over a connection that doesn't exist.
//     This UI enum's `.noHelper` is instead driven from
//     `HelperClientConnectionState` directly (see
//     `GogglesConnectionCoordinator.handleConnectionStateChange`) -- exactly
//     the "compose, don't conflate" instruction in the task brief.
//   - The live/stalled/handshaking-by-silence zone is the one place this
//     task's enum *does* add independent app-side logic on top of what the
//     helper reports: see `GogglesUIStateMachine.applySilenceWatchdog`'s
//     doc comment for why (design §6's exact 2s/5s rule needs precise,
//     locally-observed timing the helper's own ~2s-cadence internal
//     watchdog doesn't guarantee, and the helper has no code path at all
//     for "recovered after a silence-triggered handshake resend" --
//     `GogglesConnectionCoordinator`'s `onNALUnit` hook fills that gap).
// ─────────────────────────────────────────────────────────────────────────

/// The app-facing 9-state UI state machine (design.md §6). Exactly 9 cases,
/// matching the design table 1:1 by name; associated data is attached only
/// where the UI actually needs it (`claimFailed`'s diagnostic reason,
/// `handshaking`'s elapsed-seconds counter, `noHelper`'s optional detail for
/// the version-mismatch sub-case -- see `GogglesUIStateKind` below for the
/// bare case list used by tests/switches that don't care about payloads).
public enum GogglesUIState: Equatable {
    /// Helper not installed/not registered, or (folded in here rather than
    /// invented as a 10th case -- see file doc comment) an XPC protocol
    /// version mismatch, which is equally "can't use the helper right now."
    /// `reason` is `nil` for the plain not-registered case.
    case noHelper(reason: String?)
    /// Helper running, no `2CA3:0020` on USB.
    case noDevice
    /// Detaching/claiming IF0/IF1, RNDIS init.
    case claiming
    /// Root claim/RNDIS-init failure (design §8.3) or an ARP-resolution
    /// timeout (design §7) -- `reason` is one of the two verbatim
    /// diagnostic strings in `GogglesDiagnostics`, distinguished by which
    /// actually happened (see `GogglesUIStateMachine.claimFailedReason`).
    case claimFailed(reason: String)
    /// ARP for `192.168.60.2`.
    case resolving
    /// Handshake sent, nothing received yet. `elapsedSeconds` is seconds
    /// since this state was entered, ticked locally by
    /// `GogglesConnectionCoordinator` (design table: "spinner + elapsed
    /// seconds").
    case handshaking(elapsedSeconds: Int)
    /// Video packets arriving, no SPS+IDR yet. Deliberately minimal
    /// placeholder scope in this task -- Task 3.5 builds the real card
    /// (design §8.1).
    case waitingForKeyframe
    /// Displaying decoded frames.
    case live
    /// Was live, no packets for > 2s (design table).
    case stalled
}

/// The bare case list, payload-free -- lets tests/views enumerate/switch on
/// "which of the 9" without having to fabricate associated-value payloads,
/// and gives `CaseIterable` for exhaustiveness checks in tests.
public enum GogglesUIStateKind: String, CaseIterable, Equatable {
    case noHelper, noDevice, claiming, claimFailed, resolving, handshaking, waitingForKeyframe, live, stalled
}

public extension GogglesUIState {
    var kind: GogglesUIStateKind {
        switch self {
        case .noHelper: return .noHelper
        case .noDevice: return .noDevice
        case .claiming: return .claiming
        case .claimFailed: return .claimFailed
        case .resolving: return .resolving
        case .handshaking: return .handshaking
        case .waitingForKeyframe: return .waitingForKeyframe
        case .live: return .live
        case .stalled: return .stalled
        }
    }
}

public extension GogglesUIStateKind {
    /// design §6: "The device-info card ... is shown in every state from
    /// `claiming` onward" -- i.e. everything except `noHelper`/`noDevice`,
    /// where there's either no helper to ask or no device to describe yet.
    var showsDeviceCard: Bool {
        switch self {
        case .noHelper, .noDevice: return false
        default: return true
        }
    }
}

/// design §7/§8.3's required diagnostic strings, kept as named constants so
/// both the state-mapping logic and the tests that check for them
/// verbatim reference the exact same literal.
public enum GogglesDiagnostics {
    /// design §8.3, verbatim requirement: "the documented user workaround
    /// is to disable the `en*` interface macOS created for the goggles in
    /// System Settings > Network, or to unplug/replug. This must be in the
    /// `claimFailed` diagnostic text, not buried in a README." -- shown
    /// when `RNDISTransport.init` throws `RNDISTransportError` (interface
    /// claim or RNDIS init failure), i.e. every `claimFailed` cause other
    /// than the ARP-timeout one below.
    public static let interfaceClaimFailed =
        "Could not claim the Goggles 3 USB interfaces (root claim or RNDIS init failed). " +
        "Workaround: disable the \"en*\" network interface macOS created for the goggles in " +
        "System Settings > Network, or unplug/replug the goggles."

    /// design §7 table row "ARP resolution timeout (3 s)", verbatim
    /// required response text. Shown when `RNDISTransport.init` throws
    /// `ARPResolver.ARPResolverError` (primary probe + multi-subnet sweep
    /// fallback both got no reply).
    public static let arpTimeout =
        "goggles did not answer on the USB network link — power-cycle the goggles"
}

/// Pure, XPC-free state-derivation logic -- the testable core of this task.
/// Nothing here touches `HelperClient`/`NSXPCConnection`; both functions
/// take plain values and return a plain `GogglesUIState`, so
/// `GogglesUIStateTests` can exercise every transition (including both
/// watchdog thresholds) with zero XPC/timer machinery.
public enum GogglesUIStateMachine {

    /// Maps one `GogglesClientProtocol.stateChanged(_:detail:)` callback
    /// (already connected -- see file doc comment for why `.noHelper` is
    /// out of scope here) to a `GogglesUIState`. `detail` is only consulted
    /// for `.claimFailed`, to pick the right one of the two verbatim
    /// diagnostic strings.
    public static func mapHelperState(_ rawState: Int, detail: String?) -> GogglesUIState {
        guard let state = GogglesXPC.GogglesState(rawValue: rawState) else {
            // Unrecognized raw value (e.g. a future helper sends a state
            // this app build doesn't know about yet) -- fail toward the
            // least presumptuous state rather than guessing or crashing.
            return .noDevice
        }
        switch state {
        case .noHelper:
            // See file doc comment -- the helper itself never actually
            // sends this over a live connection (there'd be no connection
            // to send it on), but the switch stays exhaustive over
            // `GogglesXPC.GogglesState` rather than silently dropping a
            // case if that type ever adds one.
            return .noHelper(reason: nil)
        case .noDevice:
            return .noDevice
        case .claiming:
            return .claiming
        case .claimFailed:
            return .claimFailed(reason: claimFailedReason(fromDetail: detail))
        case .resolving:
            return .resolving
        case .handshaking:
            return .handshaking(elapsedSeconds: 0)
        case .waitingForKeyframe:
            return .waitingForKeyframe
        case .live:
            return .live
        case .stalled:
            return .stalled
        }
    }

    /// Distinguishes the two `claimFailed` causes (task brief point 4:
    /// "the diagnostic text shown should be specific to which one actually
    /// happened, not one generic string for both") from the `detail`
    /// string `HelperService.beginStreaming` sends, which is
    /// `(error as NSError).localizedDescription` for whatever
    /// `RNDISTransport.init` threw.
    ///
    /// Neither `RNDISTransportError` nor `ARPResolver.ARPResolverError`
    /// conforms to `LocalizedError`, so Foundation's automatic
    /// Swift-error-to-`NSError` bridging produces its generic fallback
    /// text -- but that fallback text always embeds the bridged error's
    /// qualified Swift type name verbatim, e.g. "The operation couldn't be
    /// completed. (GogglesUSB.ARPResolver.ARPResolverError error 0.)"
    /// (verified empirically: bridging a nested Swift error type and
    /// reading `.localizedDescription` reliably includes
    /// "<Module>.<Outer>.<TypeName>"). That type-name substring is what
    /// this checks for -- more robust than trying to match on
    /// human-readable wording, which either error's `description` never
    /// even reaches here since only `NSError.localizedDescription` crosses
    /// the XPC boundary as `detail`.
    static func claimFailedReason(fromDetail detail: String?) -> String {
        guard let detail, detail.contains("ARPResolverError") else {
            return GogglesDiagnostics.interfaceClaimFailed
        }
        return GogglesDiagnostics.arpTimeout
    }

    /// design §6's exact silence-watchdog rule:
    ///   - from `.live`, >= 2s of silence -> `.stalled` ("was live, no
    ///     packets for > 2s").
    ///   - a further escalation to >= 5s of *total* silence (measured from
    ///     the same last-activity timestamp, not restarted at `.stalled`)
    ///     -> `.handshaking`, **not** `.waitingForKeyframe` (design's
    ///     explicit transition note: "the handshake must be
    ///     re-established first").
    ///   - anything under 2s while live/stalled resolves back to `.live`
    ///     (covers the ordinary steady-state tick, and recovery from a
    ///     brief stall once fresh data arrives, without needing a separate
    ///     "un-stall" code path).
    ///
    /// Deliberately a no-op for every other `current.kind` -- silence
    /// before ever reaching `.live` is normal (no video has started yet)
    /// and is already covered by the helper's own pre-live state
    /// reporting via `mapHelperState`; this function must never fight that
    /// reporting by, say, forcing `.claiming` into `.stalled` because no
    /// NAL has arrived yet (none is expected to, this early).
    ///
    /// Why this app-side timer exists at all rather than trusting the
    /// helper's own ~2s-cadence `pipelineWentSilent()` cascade
    /// (`HelperService.swift`): that cascade needs *two* consecutive
    /// ~2s-silence detections to reach `.handshaking` (~4s, not design's
    /// exact 5s), and — more importantly — has no code path back to
    /// `.live` once escalated (`pipelineDidStart()` only ever fires once
    /// per running pipeline `Task`, on the very first started-gate
    /// opening). `GogglesConnectionCoordinator` closes that recovery gap
    /// itself (see its `onNALUnit` handler); this function only needs to
    /// get the two thresholds exactly right against locally-observed
    /// silence.
    public static func applySilenceWatchdog(
        current: GogglesUIState,
        secondsSinceLastActivity: TimeInterval
    ) -> GogglesUIState {
        switch current.kind {
        case .live, .stalled:
            if secondsSinceLastActivity >= 5.0 {
                return .handshaking(elapsedSeconds: 0)
            } else if secondsSinceLastActivity >= 2.0 {
                return .stalled
            } else {
                return .live
            }
        default:
            return current
        }
    }
}
