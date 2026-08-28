import Foundation
import CoreMedia

// ─────────────────────────────────────────────────────────────────────────
// Task 3.2, design.md §5.3: the goggles bundle SPS (type 7) and PPS (type 8)
// together in a single ~40-byte Annex-B blob (see `Fixtures/sps_pps.bin`,
// extracted from the real corpus). `stream.py`'s helper-side gate
// (`nalType in (7, 8)` then `nalType == 5`) is fine for a raw Annex-B byte
// sink, but VideoToolbox's
// `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants SPS and PPS as
// two *separate* pointers, without their Annex-B start codes. This file is
// the app-side (not helper-side, per §5.3) split + format-description build.
//
// Scope: this stops at producing a valid `CMVideoFormatDescription`. Slice
// NAL Annex-B -> AVCC conversion and `CMSampleBuffer` wrapping is Task 3.3's
// job (explicitly out of scope per the design doc's note in §5.3).
// ─────────────────────────────────────────────────────────────────────────

/// One H.264 NAL unit split out of an Annex-B blob: `type` is `nal[0] & 0x1F`
/// and `payload` is the raw NAL bytes (header byte included, start code
/// excluded) -- exactly the form `CMVideoFormatDescriptionCreateFromH264ParameterSets`
/// wants for a parameter set.
struct NALUnit: Equatable {
    let type: UInt8
    let payload: [UInt8]
}

enum ParameterSetError: Error, Equatable {
    /// The blob split into NALs but no type-7 (SPS) was among them.
    case missingSPS
    /// The blob split into NALs but no type-8 (PPS) was among them.
    case missingPPS
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` itself failed;
    /// carries its `OSStatus`.
    case formatDescriptionCreationFailed(OSStatus)
}

enum ParameterSetSplitter {

    /// Splits an Annex-B byte blob into individual NAL units.
    ///
    /// design.md §5.3 point 1: "Scan the blob for internal `00 00 01` /
    /// `00 00 00 01` start codes and split it into individual NALs." Per the
    /// task-3.2 brief, the real bundled blob (`Fixtures/sps_pps.bin`) is not
    /// assumed to use one or the other -- both 3-byte and 4-byte start codes
    /// are detected here, NAL by NAL, independent of which one delimits any
    /// given pair.
    ///
    /// A blob with no start code at all (malformed input) yields an empty
    /// array rather than throwing -- there is nothing NAL-shaped to report,
    /// and callers (see `ParameterSetFormatDescriptionCache`) already treat
    /// "no SPS found" / "no PPS found" as the actionable error condition.
    static func split(_ blob: [UInt8]) -> [NALUnit] {
        let ranges = startCodeRanges(in: blob)
        guard !ranges.isEmpty else { return [] }

        var nals: [NALUnit] = []
        nals.reserveCapacity(ranges.count)
        for (index, range) in ranges.enumerated() {
            let payloadStart = range.upperBound
            let payloadEnd = index + 1 < ranges.count ? ranges[index + 1].lowerBound : blob.count
            guard payloadStart < payloadEnd else { continue }
            let payload = Array(blob[payloadStart..<payloadEnd])
            guard let header = payload.first else { continue }
            nals.append(NALUnit(type: header & 0x1F, payload: payload))
        }
        return nals
    }

    /// Locates every Annex-B start code in `blob`, returning each as the
    /// byte range it occupies (3 bytes for `00 00 01`, 4 for `00 00 00 01`).
    ///
    /// Scans for the 3-byte `00 00 01` pattern (the minimal Annex-B start
    /// code) and, whenever the byte immediately preceding a match is also
    /// `0x00`, extends the range left by one byte to capture the 4-byte
    /// form. Matches never overlap: the scan resumes immediately after each
    /// found 3-byte pattern.
    private static func startCodeRanges(in blob: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        let n = blob.count
        while i + 2 < n {
            if blob[i] == 0x00, blob[i + 1] == 0x00, blob[i + 2] == 0x01 {
                if i >= 1, blob[i - 1] == 0x00 {
                    ranges.append((i - 1)..<(i + 3))
                } else {
                    ranges.append(i..<(i + 3))
                }
                i += 3
            } else {
                i += 1
            }
        }
        return ranges
    }

    /// Builds a `CMVideoFormatDescription` from separate SPS/PPS parameter
    /// sets (start codes already stripped), per design.md §5.3 point 3:
    /// "Build the `CMVideoFormatDescription` from those two, with
    /// `nalUnitHeaderLength = 4`."
    ///
    /// `nalUnitHeaderLength: 4` describes the length prefix VideoToolbox
    /// should expect on *slice* NALs decoded against this format
    /// description later (Task 3.3's Annex-B -> AVCC conversion uses 4-byte
    /// big-endian length prefixes) -- it has no bearing on how the
    /// parameter sets themselves are passed here, which is as bare
    /// pointer+size pairs with no length prefix or start code at all.
    static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) throws -> CMVideoFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer -> OSStatus in
            pps.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes: [Int] = [spsBuffer.count, ppsBuffer.count]
                return pointers.withUnsafeBufferPointer { pointersBuffer -> OSStatus in
                    sizes.withUnsafeBufferPointer { sizesBuffer -> OSStatus in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }
        guard status == noErr, let formatDescription else {
            throw ParameterSetError.formatDescriptionCreationFailed(status)
        }
        return formatDescription
    }

    /// Convenience combining `split(_:)` + parameter-set extraction +
    /// `makeFormatDescription(sps:pps:)` in one call, for a raw bundled
    /// SPS+PPS blob straight off the wire.
    static func formatDescription(fromBundledBlob blob: [UInt8]) throws -> CMVideoFormatDescription {
        let nals = split(blob)
        guard let sps = nals.first(where: { $0.type == 7 })?.payload else {
            throw ParameterSetError.missingSPS
        }
        guard let pps = nals.first(where: { $0.type == 8 })?.payload else {
            throw ParameterSetError.missingPPS
        }
        return try makeFormatDescription(sps: sps, pps: pps)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// design.md §5.3 point 4: "Rebuild the format description whenever a
// *different* parameter-set blob arrives (compare bytes; identical blobs
// are ignored)." A one-shot pure function isn't enough for that -- later
// tasks (3.3+) call this repeatedly, once per received parameter-set blob,
// and rebuilding VideoToolbox state on every call regardless of whether
// anything changed would be wasteful and (worse) would needlessly disturb
// any in-flight decode session keyed off format description identity. This
// class is the stateful memoization wrapper around
// `ParameterSetSplitter.formatDescription(fromBundledBlob:)`.
// ─────────────────────────────────────────────────────────────────────────

/// Holds the last-seen parameter-set blob and its derived
/// `CMVideoFormatDescription`, rebuilding only when a byte-different blob
/// arrives. Not thread-safe by design -- like `NALFPSCounter`/`HelperClient`
/// state, callers are expected to serialize access on their own queue (the
/// XPC callback queue, in the eventual Task 3.3 caller).
final class ParameterSetFormatDescriptionCache {
    private(set) var formatDescription: CMVideoFormatDescription?
    private var lastBlob: [UInt8]?

    /// Incremented every time `update(withBundledBlob:)` actually rebuilds
    /// the format description (as opposed to returning the cached one
    /// because the blob was byte-identical to the last one seen). Exists
    /// purely so the memoization behavior is directly assertable in tests,
    /// independent of `CMFormatDescription`'s CoreFoundation identity
    /// semantics.
    private(set) var rebuildCount = 0

    init() {}

    /// Updates the cache with a freshly-received bundled SPS+PPS blob.
    ///
    /// If `blob` is byte-identical to the last blob this cache saw, the
    /// existing `CMVideoFormatDescription` is returned unchanged and
    /// `rebuildCount` does not increment. Otherwise the blob is split,
    /// a new format description is built, and it becomes both the return
    /// value and the new cached `formatDescription`.
    @discardableResult
    func update(withBundledBlob blob: [UInt8]) throws -> CMVideoFormatDescription {
        if let lastBlob, lastBlob == blob, let formatDescription {
            return formatDescription
        }
        let newFormatDescription = try ParameterSetSplitter.formatDescription(fromBundledBlob: blob)
        lastBlob = blob
        formatDescription = newFormatDescription
        rebuildCount += 1
        return newFormatDescription
    }

    /// Clears cached state entirely -- forces the next
    /// `update(withBundledBlob:)` call to rebuild unconditionally, even if
    /// the blob that then arrives is byte-identical to the last one this
    /// cache saw before the reset.
    ///
    /// Task 3.3, design.md §7's 30-consecutive-failure teardown row: "tear
    /// down the decode session (drop the cached format description...) and
    /// wait for the next parameter set." Clearing `formatDescription` alone
    /// would satisfy "drop the cached format description," but leaving
    /// `lastBlob` in place would mean a stream that keeps re-announcing the
    /// same bundled SPS+PPS blob (rather than a genuinely fresh one from a
    /// goggles-side Liveview toggle) could never trigger the rebuild the
    /// teardown path is waiting for -- `update`'s memoization guard would
    /// keep returning "unchanged, skip" against a `formatDescription` that
    /// no longer exists. Clearing both together is what makes "wait for the
    /// next parameter set" actually resume decoding on the very next
    /// parameter-set NAL, identical bytes or not.
    func reset() {
        formatDescription = nil
        lastBlob = nil
    }
}
