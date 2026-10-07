import Testing
import CoreMedia
import Foundation
@testable import GogglesView
import GogglesH264

// ─────────────────────────────────────────────────────────────────────────
// Task 3.2, design.md §9.1 item 4 (verbatim): "Parameter-set split test on
// the real ~40-byte bundled blob from the corpus: asserts two NALs out,
// types 7 and 8, and that `CMVideoFormatDescriptionCreateFromH264ParameterSets`
// succeeds with 1920x1080." `bundledBlobTest` below is exactly that test.
//
// `Fixtures/sps_pps.bin` (repo root) is the real bundled blob, confirmed by
// reading its raw bytes:
//   00 00 00 01 67 64 00 34 ac 4d 00 f0 04 4f cb 35
//   01 01 01 40 00 00 03 00 40 00 00 1e 03 c7 0c a8
//   00 00 00 01 68 ee 3c b0
// i.e. BOTH internal start codes are the 4-byte `00 00 00 01` form here --
// not the 3-byte `00 00 01` the brief's own worked example used. The
// splitter must not assume either form (design.md §5.3 point 1), which is
// why `startCodeAgnosticSplit` below separately exercises the 3-byte form
// with synthetic bytes.
// ─────────────────────────────────────────────────────────────────────────

@Suite("ParameterSetSplitter")
struct ParameterSetSplitterTests {

    /// Locates `Fixtures/sps_pps.bin` relative to this source file
    /// (`Apps/GogglesView/Tests/GogglesViewTests/` -> repo root is four
    /// directories up), rather than relying on the test runner's current
    /// working directory, which `swift test` does not guarantee points at
    /// the repo root.
    static func loadBundledFixtureBlob() throws -> [UInt8] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // ParameterSetSplitterTests.swift -> GogglesViewTests/
            .deletingLastPathComponent() // GogglesViewTests/ -> Tests/
            .deletingLastPathComponent() // Tests/ -> GogglesView/ (the SPM package dir)
            .deletingLastPathComponent() // GogglesView/ -> Apps/
            .deletingLastPathComponent() // Apps/ -> repo root
        let fixtureURL = repoRoot.appendingPathComponent("Fixtures/sps_pps.bin")
        let data = try Data(contentsOf: fixtureURL)
        return [UInt8](data)
    }

    @Test("design.md §9.1 item 4 — bundled blob splits to SPS+PPS and yields 1920x1080")
    func bundledBlobTest() throws {
        let blob = try Self.loadBundledFixtureBlob()

        let nals = ParameterSetSplitter.split(blob)
        #expect(nals.count == 2)
        #expect(Set(nals.map(\.type)) == [7, 8])

        let sps = try #require(nals.first(where: { $0.type == 7 }))
        let pps = try #require(nals.first(where: { $0.type == 8 }))

        let formatDescription = try ParameterSetSplitter.makeFormatDescription(sps: sps.payload, pps: pps.payload)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        #expect(dimensions.width == 1920)
        #expect(dimensions.height == 1080)
    }

    @Test("formatDescription(fromBundledBlob:) convenience matches the manual split+build path")
    func bundledBlobConvenienceMethod() throws {
        let blob = try Self.loadBundledFixtureBlob()
        let formatDescription = try ParameterSetSplitter.formatDescription(fromBundledBlob: blob)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        #expect(dimensions.width == 1920)
        #expect(dimensions.height == 1080)
    }

    @Test("splitter handles the 3-byte 00 00 01 start-code form, not just 4-byte")
    func startCodeAgnosticSplit() {
        // Same SPS/PPS payload bytes as the real fixture, but joined with
        // 3-byte start codes throughout, confirming the brief's warning
        // that "some bundled blobs use 3-byte 00 00 01, others 4-byte
        // 00 00 00 01" is handled either way.
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x34, 0xac]
        let pps: [UInt8] = [0x68, 0xee, 0x3c, 0xb0]
        let blob: [UInt8] = [0x00, 0x00, 0x01] + sps + [0x00, 0x00, 0x01] + pps

        let nals = ParameterSetSplitter.split(blob)
        #expect(nals.count == 2)
        #expect(nals[0].type == 7)
        #expect(nals[0].payload == sps)
        #expect(nals[1].type == 8)
        #expect(nals[1].payload == pps)
    }

    @Test("blob with no start code at all splits to zero NALs")
    func noStartCodeYieldsEmpty() {
        let blob: [UInt8] = [0x67, 0x64, 0x00, 0x34, 0xac, 0x4d]
        #expect(ParameterSetSplitter.split(blob).isEmpty)
    }

    @Test("blob with only a single NAL splits to exactly one")
    func singleNALBlob() {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x34, 0xac]
        let blob: [UInt8] = [0x00, 0x00, 0x00, 0x01] + sps
        let nals = ParameterSetSplitter.split(blob)
        #expect(nals.count == 1)
        #expect(nals[0].type == 7)
        #expect(nals[0].payload == sps)
    }

    @Test("formatDescription(fromBundledBlob:) throws .missingPPS when only SPS is present")
    func missingPPSThrows() throws {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x34, 0xac]
        let blob: [UInt8] = [0x00, 0x00, 0x00, 0x01] + sps
        #expect(throws: ParameterSetError.missingPPS) {
            _ = try ParameterSetSplitter.formatDescription(fromBundledBlob: blob)
        }
    }

    @Test("formatDescription(fromBundledBlob:) throws .missingSPS when only PPS is present")
    func missingSPSThrows() throws {
        let pps: [UInt8] = [0x68, 0xee, 0x3c, 0xb0]
        let blob: [UInt8] = [0x00, 0x00, 0x00, 0x01] + pps
        #expect(throws: ParameterSetError.missingSPS) {
            _ = try ParameterSetSplitter.formatDescription(fromBundledBlob: blob)
        }
    }
}

@Suite("ParameterSetFormatDescriptionCache")
struct ParameterSetFormatDescriptionCacheTests {

    @Test("identical blob bytes are ignored — no rebuild, same cached description")
    func identicalBlobDoesNotRebuild() throws {
        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        let cache = ParameterSetFormatDescriptionCache()

        let first = try cache.update(withBundledBlob: blob)
        #expect(cache.rebuildCount == 1)

        let second = try cache.update(withBundledBlob: blob)
        #expect(cache.rebuildCount == 1) // unchanged: not rebuilt
        #expect(CMFormatDescriptionEqual(first, otherFormatDescription: second))
    }

    @Test("a byte-different blob triggers a rebuild")
    func differentBlobRebuilds() throws {
        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        let cache = ParameterSetFormatDescriptionCache()

        _ = try cache.update(withBundledBlob: blob)
        #expect(cache.rebuildCount == 1)

        // Same SPS/PPS content, but with an extra no-op start code sequence
        // spliced in front, making the byte blob different even though the
        // decoded parameter sets end up equivalent -- the memoization
        // compares raw bytes, not decoded semantics, per design.md §5.3
        // point 4 ("compare bytes").
        var mutatedBlob = blob
        mutatedBlob.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        _ = try cache.update(withBundledBlob: mutatedBlob)
        #expect(cache.rebuildCount == 2)
    }

    @Test("cache starts with no format description before the first update")
    func startsEmpty() {
        let cache = ParameterSetFormatDescriptionCache()
        #expect(cache.formatDescription == nil)
        #expect(cache.rebuildCount == 0)
    }
}
