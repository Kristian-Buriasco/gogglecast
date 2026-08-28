import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 2.1: `StreamStats` field list is not enumerated in design §5.5 (the
// brief calls it out as needing to be inferred). Sourced from `gvcli`'s
// `--stats` reporting (task 1.7), which is the only place this codebase
// currently computes/reports streaming stats end-to-end:
//
//   Tools/gvcli/Sources/gvcli/Pipeline.swift (per-second stats block):
//     "[stats] t=%4ds fps=%3d bitrate=%9.1fkbps drops=%d
//              cum_frames=%d cum_bytes=%d cum_drops=%d"
//
//   Tools/gvcli/Sources/gvcli/PipelineState.swift (the actor backing those
//   numbers): per-second frameCount/byteCount/dropCount (reset every
//   second) plus cumulativeFrameCount/cumulativeByteCount/
//   cumulativeDropCount (running totals since stream start).
//
// `StreamStats` mirrors that exact set of 7 numbers so a future helper
// (task 2.2+) can report over XPC using the same counters gvcli already
// proves out, and a future app UI (task 3.1+) gets the same numbers gvcli
// prints to stdout today.
// ─────────────────────────────────────────────────────────────────────────

/// XPC-transportable streaming statistics snapshot, reported by the helper
/// to subscribed clients (design §5.5, `GogglesClientProtocol.stats`).
public final class StreamStats: NSObject, NSSecureCoding {

    /// Frames emitted in the most recently completed one-second window.
    public let fps: Int
    /// Bitrate over that same window, in kbps (`bytes * 8 / 1000`), matching
    /// gvcli's `bitrate=%9.1fkbps` field.
    public let bitrateKbps: Double
    /// Frames dropped (per `FrameReassembler.droppedFrameCount`, design
    /// §9.2) in that same one-second window.
    public let drops: Int
    /// Running total of frames emitted since streaming started.
    public let cumulativeFrames: Int
    /// Running total of bytes emitted since streaming started.
    public let cumulativeBytes: Int
    /// Running total of dropped frames since streaming started.
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

    // MARK: - NSSecureCoding

    public static var supportsSecureCoding: Bool { true }

    private enum Key {
        static let fps = "fps"
        static let bitrateKbps = "bitrateKbps"
        static let drops = "drops"
        static let cumulativeFrames = "cumulativeFrames"
        static let cumulativeBytes = "cumulativeBytes"
        static let cumulativeDrops = "cumulativeDrops"
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int32(fps), forKey: Key.fps)
        coder.encode(bitrateKbps, forKey: Key.bitrateKbps)
        coder.encode(Int32(drops), forKey: Key.drops)
        coder.encode(Int64(cumulativeFrames), forKey: Key.cumulativeFrames)
        coder.encode(Int64(cumulativeBytes), forKey: Key.cumulativeBytes)
        coder.encode(Int64(cumulativeDrops), forKey: Key.cumulativeDrops)
    }

    public required init?(coder: NSCoder) {
        fps = Int(coder.decodeInt32(forKey: Key.fps))
        bitrateKbps = coder.decodeDouble(forKey: Key.bitrateKbps)
        drops = Int(coder.decodeInt32(forKey: Key.drops))
        cumulativeFrames = Int(coder.decodeInt64(forKey: Key.cumulativeFrames))
        cumulativeBytes = Int(coder.decodeInt64(forKey: Key.cumulativeBytes))
        cumulativeDrops = Int(coder.decodeInt64(forKey: Key.cumulativeDrops))
    }
}
