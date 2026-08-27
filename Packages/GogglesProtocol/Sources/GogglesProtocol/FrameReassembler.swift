import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 1.3: video-fragment reassembler (design §5.2).
//
// Swift port of `stream.py`'s inline reassembly logic (the `frames` /
// `frame_expected_count` dicts, `flush_frame`, and the main loop's
// frame-number-change / fragment-count-reached branches), with the two
// corrections the brief calls out as required, not optional:
//
//   (a) age-based eviction: a frame entry is dropped once it is more than
//       5 frame-numbers old (mod-256 distance) OR more than 250ms old --
//       whichever fires first. `stream.py` only ever evicts the *current*
//       frame number (on a frame-number change or fragment-count-reached),
//       so a fragment lost mid-frame leaves that entry parked forever; if
//       frame numbers ever wrap back around to the same value (they do,
//       every 256 frames) a later frame silently merges into the stale
//       one, producing a corrupt NAL.
//
//   (b) discard, not merge: when a stale/incomplete entry is evicted, its
//       fragments are thrown away (never concatenated), and a running
//       drop counter is incremented. `stream.py` has no such counter and
//       no such discard path at all -- this is new behavior, not a port.
//
// Pure Foundation, no I/O, no networking -- matches the rest of this
// package's zero-dependency constraint (design, `GogglesProtocol.swift`).
// ─────────────────────────────────────────────────────────────────────────

/// Reassembles fragmented H.264 NAL units from video-packet payloads
/// (type `0x02`, design §5.2), matching and correcting `stream.py`'s
/// `frames` / `frame_expected_count` / `flush_frame` logic.
///
/// Not thread-safe; callers should confine an instance to one queue/thread,
/// same as the rest of this package's stateless-by-default design.
public final class FrameReassembler {

    // MARK: - Public API

    /// Number of frame entries discarded (as opposed to successfully
    /// completed) because they were evicted while still incomplete --
    /// either aged out (stale-entry correction, design §5.2) or bumped by
    /// a fragment-count-reached/frame-number-change event on some *other*
    /// still-incomplete entry. This has no counterpart in `stream.py`,
    /// which silently merges instead (the bug this task fixes).
    public private(set) var droppedFrameCount: Int = 0

    /// Max mod-256 distance (§5.2) before a frame entry is considered
    /// stale and evicted regardless of wall-clock age.
    public static let maxFrameAgeDistance: UInt8 = 5

    /// Max wall-clock age (§5.2) before a frame entry is considered stale
    /// and evicted regardless of mod-256 distance.
    public static let maxFrameAgeInterval: TimeInterval = 0.250

    public init() {}

    /// Feeds one video-packet payload (post outer-header -- i.e. what
    /// Task 1.2's `buildOuter`/parsing infrastructure hands off, starting
    /// at outer-header offset 8) into the reassembler.
    ///
    /// `receivedAt` is the caller-supplied "now" for this packet (design
    /// says to make the clock injectable rather than calling `Date()`
    /// internally, so tests can drive it deterministically). Pass
    /// `Date()` at the real call site.
    ///
    /// Returns a completed NAL unit (with a `00 00 00 01` start code
    /// prepended if the reassembled bytes don't already carry one) once
    /// a frame's fragment count is reached, or `nil` if more fragments
    /// are still expected. Malformed payloads (too short to contain the
    /// 12-byte video sub-header) are ignored and return `nil`.
    @discardableResult
    public func process(videoPayload: Data, receivedAt: Date) -> Data? {
        // §5.2: 12-byte sub-header starts right after the 8-byte outer
        // header, which the caller has already stripped -- so here offset
        // 0 in `videoPayload` corresponds to outer-header offset 8.
        // Sub-header fields of interest are therefore at *local* offsets
        // 8 (frame number), 9 (frag-count/frag-lsb byte), 10 (frag-num
        // high bits); raw H.264 payload starts at local offset 12.
        guard videoPayload.count >= 12 else { return nil }

        let base = videoPayload.startIndex
        let frameNum = videoPayload[base + 8]
        let b17 = videoPayload[base + 9]
        let b18 = videoPayload[base + 10]
        let fragCount = b17 & 0x7F
        let fragNum = ((b18 & 0x1F) << 1) | (b17 >> 7)
        let chunk = videoPayload.subdata(in: (base + 12)..<videoPayload.endIndex)

        // Correction (a): evict any entry that's gone stale (mod-256
        // distance > 5 or age > 250ms) before touching the entry for
        // this packet's frame number. Discard evicted-while-incomplete
        // entries per correction (b).
        evictStaleEntries(currentFrameNum: frameNum, now: receivedAt)

        var entry = entries[frameNum] ?? Entry(expectedCount: fragCount, firstSeenAt: receivedAt)
        entry.expectedCount = fragCount // §5.2/stream.py: last-seen count wins, matches frame_expected_count[frame_num] = frag_count every packet.
        entry.fragments[fragNum] = chunk
        entries[frameNum] = entry

        guard entry.fragments.count >= Int(fragCount), fragCount > 0 else {
            return nil
        }

        // Complete: pop, concatenate in ascending fragment-index order,
        // emit. (`stream.py`'s flush_frame`.)
        entries.removeValue(forKey: frameNum)
        return Self.assembleNAL(from: entry.fragments)
    }

    // MARK: - Private state

    private struct Entry {
        var fragments: [UInt8: Data] = [:]
        var expectedCount: UInt8
        var firstSeenAt: Date
    }

    private var entries: [UInt8: Entry] = [:]

    // MARK: - Eviction

    /// Modulo-256 distance from `from` to `to`, i.e. how many steps
    /// forward from `from` (wrapping at 256) reach `to`. E.g. distance
    /// from 250 to 3 is 9 (250 -> 255 -> 0 -> 3), not |250-3| = 247.
    static func mod256Distance(from: UInt8, to: UInt8) -> Int {
        Int(to &- from)
    }

    /// Drops every entry whose mod-256 distance behind `currentFrameNum`
    /// exceeds `maxFrameAgeDistance`, or whose age exceeds
    /// `maxFrameAgeInterval` -- whichever check fires first, per §5.2's
    /// "modulo-256 distance > 5 or > 250 ms". Every eviction here is by
    /// definition of a still-incomplete entry (a complete one is popped
    /// synchronously in `process` the moment it completes and never
    /// lingers in `entries`), so every eviction increments the drop
    /// counter -- this is correction (b).
    private func evictStaleEntries(currentFrameNum: UInt8, now: Date) {
        // Snapshot the keys first: removing entries while iterating the
        // dictionary directly is undefined behavior in Swift (and crashes
        // in practice).
        for num in Array(entries.keys) {
            guard let entry = entries[num] else { continue }
            let distance = Self.mod256Distance(from: num, to: currentFrameNum)
            let age = now.timeIntervalSince(entry.firstSeenAt)
            if distance > Int(Self.maxFrameAgeDistance) || age > Self.maxFrameAgeInterval {
                entries.removeValue(forKey: num)
                droppedFrameCount += 1
            }
        }
    }

    // MARK: - Assembly

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private static func assembleNAL(from fragments: [UInt8: Data]) -> Data? {
        var data = Data()
        for key in fragments.keys.sorted() {
            data.append(fragments[key]!)
        }
        guard !data.isEmpty else { return nil }
        if data.count >= 4 && data.prefix(4).elementsEqual(startCode) {
            return data
        }
        return Data(startCode) + data
    }
}
