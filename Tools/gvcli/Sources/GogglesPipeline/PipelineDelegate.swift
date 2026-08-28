import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: the hook `runPipeline` uses to hand events to a consumer beyond
// "write Annex-B to an `OutputSink`" -- specifically `GogglesHelper --xpc`
// mode's per-subscriber `nalUnit`/`stateChanged`/`stats` fan-out (design
// §5.5). `gvcli` (both `stream` and `replay`) never passes a delegate; its
// existing stderr text banners are untouched by this addition. Every
// method has a default no-op via the protocol extension below so a
// conformer only implements what it actually uses.
// ─────────────────────────────────────────────────────────────────────────

/// Optional event sink for `runPipeline`. Fired *in addition to* (never
/// instead of) whatever `OutputSink`/stderr behavior `runPipeline` already
/// has -- this does not change gvcli's own behavior in any way.
public protocol PipelineDelegate: AnyObject {
    /// Every NAL unit `runPipeline` emits post-started-gate (or the SPS/PPS
    /// parameter set that opens the gate), start-code included, same bytes
    /// as whatever's written to the `OutputSink`. `hostTime` is
    /// `DispatchTime.now().uptimeNanoseconds` at the moment of emission.
    func pipeline(didEmitNAL data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64)
    /// The first inbound video packet was observed, before the SPS+IDR
    /// started-gate has opened -- design §6's `.waitingForKeyframe`.
    func pipelineDidBeginReceivingVideo()
    /// The started-gate opened (a parameter set followed by an IDR was
    /// seen, output began) -- design §6's `.live`.
    func pipelineDidStart()
    /// No inbound data for >2s, so the periodic timer resent the
    /// handshake -- design §6's `.handshaking` if this fires before the
    /// gate ever opened, or `.stalled` if it fires after `pipelineDidStart`
    /// already ran once (the caller, which knows whether it has reached
    /// `.live` before, decides which).
    func pipelineWentSilent()
    /// Once-per-second stats snapshot -- fires whenever `runPipeline` is
    /// given a non-nil delegate, independent of gvcli's own `--stats` flag
    /// (which only controls the separate stderr `[stats]` line). Mirrors
    /// `GogglesXPC.StreamStats`'s field set without this library depending
    /// on `GogglesXPC`; `GogglesHelper` converts one of these at the XPC
    /// boundary.
    func pipelineDidUpdateStats(_ stats: PipelineStats)
}

public extension PipelineDelegate {
    func pipeline(didEmitNAL data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {}
    func pipelineDidBeginReceivingVideo() {}
    func pipelineDidStart() {}
    func pipelineWentSilent() {}
    func pipelineDidUpdateStats(_ stats: PipelineStats) {}
}

/// See `PipelineDelegate.pipelineDidUpdateStats`. Field set mirrors
/// `GogglesXPC.StreamStats` exactly (fps, bitrateKbps, drops this second;
/// cumulativeFrames/Bytes/Drops since stream start) -- see that type's doc
/// comment for where the numbers originally come from
/// (`Pipeline.swift`/`PipelineState.swift`'s per-second stats block).
public struct PipelineStats: Sendable {
    public let fps: Int
    public let bitrateKbps: Double
    public let drops: Int
    public let cumulativeFrames: Int
    public let cumulativeBytes: Int
    public let cumulativeDrops: Int

    public init(
        fps: Int,
        bitrateKbps: Double,
        drops: Int,
        cumulativeFrames: Int,
        cumulativeBytes: Int,
        cumulativeDrops: Int
    ) {
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.drops = drops
        self.cumulativeFrames = cumulativeFrames
        self.cumulativeBytes = cumulativeBytes
        self.cumulativeDrops = cumulativeDrops
    }
}
