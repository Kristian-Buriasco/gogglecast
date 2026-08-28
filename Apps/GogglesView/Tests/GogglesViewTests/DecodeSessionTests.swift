import Testing
import CoreMedia
import Foundation
@testable import GogglesView

// ─────────────────────────────────────────────────────────────────────────
// Task 3.3: exercises `DecodeSession`'s slice-NAL handling and design.md
// §7's error policy WITHOUT any real hardware/VideoToolbox decode --
// `MockRenderer` below stands in for the `AVSampleBufferDisplayLayer`
// `DecodeSession` would otherwise drive, so the 30-consecutive-failure
// teardown path (in particular) is exercised with synthetic bad NALs, per
// the task brief's "can likely be unit-tested with synthetic bad samples,
// doesn't need real hardware" note.
// ─────────────────────────────────────────────────────────────────────────

/// Records every `enqueue`/`flush` call instead of actually rendering
/// anything.
final class MockRenderer: SampleBufferRendering {
    private(set) var enqueuedCount = 0
    private(set) var flushCount = 0

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        enqueuedCount += 1
    }

    func flush() {
        flushCount += 1
    }
}

@Suite("DecodeSession")
struct DecodeSessionTests {

    /// A syntactically well-formed (start-code-prefixed) but semantically
    /// meaningless slice NAL -- sufficient to exercise
    /// `NALAnnexBToAVCC.convert`/`CMSampleBuffer` construction, since
    /// neither validates actual H.264 bitstream content, only structure.
    static let wellFormedSliceNAL = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00, 0x10, 0x20])
    /// Deliberately missing its start code -- `NALAnnexBToAVCC.convert`
    /// throws `.noStartCode` on this, modeling design.md §7's "Corrupt/
    /// undecodable NAL" row without needing a real VideoToolbox failure.
    static let malformedSliceNAL = Data([0x65, 0x88, 0x84, 0x00, 0x10, 0x20])

    @Test("a slice NAL arriving before any parameter set is silently dropped, not a failure")
    func noFormatDescriptionYetIsNotAFailure() throws {
        let session = DecodeSession()
        let renderer = MockRenderer()
        session.attach(renderer: renderer)
        var droppedCount = 0
        session.onDroppedSample = { _ in droppedCount += 1 }

        session.handle(nalData: Self.wellFormedSliceNAL, nalType: 1, isParameterSet: false, hostTime: 1)

        #expect(renderer.enqueuedCount == 0)
        #expect(droppedCount == 0) // not counted as a dropped-sample failure
        #expect(session.consecutiveFailures == 0)
        #expect(!session.hasFormatDescription)
    }

    @Test("a valid parameter set followed by a well-formed slice NAL enqueues one sample buffer")
    func validSliceAfterParameterSetEnqueues() throws {
        let session = DecodeSession()
        let renderer = MockRenderer()
        session.attach(renderer: renderer)

        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        session.handle(nalData: Data(blob), nalType: 7, isParameterSet: true, hostTime: 0)
        #expect(session.hasFormatDescription)

        session.handle(nalData: Self.wellFormedSliceNAL, nalType: 1, isParameterSet: false, hostTime: 12_345)

        #expect(renderer.enqueuedCount == 1)
        #expect(session.consecutiveFailures == 0)
    }

    @Test("design.md §7: 30 consecutive corrupt slice NALs tear down the session")
    func thirtyConsecutiveFailuresTearDown() throws {
        let session = DecodeSession()
        let renderer = MockRenderer()
        session.attach(renderer: renderer)
        var teardownCount = 0
        session.onTeardown = { teardownCount += 1 }
        var droppedCount = 0
        session.onDroppedSample = { _ in droppedCount += 1 }

        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        session.handle(nalData: Data(blob), nalType: 7, isParameterSet: true, hostTime: 0)
        #expect(session.hasFormatDescription)

        for i in 0..<(DecodeSession.maxConsecutiveFailures - 1) {
            session.handle(nalData: Self.malformedSliceNAL, nalType: 1, isParameterSet: false, hostTime: UInt64(i))
        }
        // 29 failures in: not torn down yet.
        #expect(session.consecutiveFailures == DecodeSession.maxConsecutiveFailures - 1)
        #expect(teardownCount == 0)
        #expect(session.hasFormatDescription)
        #expect(renderer.flushCount == 0)

        // The 30th failure crosses the threshold.
        session.handle(nalData: Self.malformedSliceNAL, nalType: 1, isParameterSet: false, hostTime: 999)

        #expect(teardownCount == 1)
        #expect(session.teardownCount == 1)
        #expect(session.consecutiveFailures == 0) // reset after teardown
        #expect(!session.hasFormatDescription) // "drop the cached format description"
        #expect(renderer.flushCount == 1) // "drop... display layer state"
        #expect(droppedCount == DecodeSession.maxConsecutiveFailures)

        // Post-teardown: a slice NAL is a clean no-op again (waiting for
        // the next parameter set), not a further failure.
        session.handle(nalData: Self.wellFormedSliceNAL, nalType: 1, isParameterSet: false, hostTime: 1000)
        #expect(session.consecutiveFailures == 0)
        #expect(renderer.enqueuedCount == 0)
    }

    @Test("after teardown, even a byte-identical parameter-set blob rebuilds and resumes decoding")
    func teardownRecoversOnIdenticalBlobResend() throws {
        let session = DecodeSession()
        let renderer = MockRenderer()
        session.attach(renderer: renderer)

        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        session.handle(nalData: Data(blob), nalType: 7, isParameterSet: true, hostTime: 0)
        #expect(session.hasFormatDescription)

        for i in 0..<DecodeSession.maxConsecutiveFailures {
            session.handle(nalData: Self.malformedSliceNAL, nalType: 1, isParameterSet: false, hostTime: UInt64(i))
        }
        #expect(!session.hasFormatDescription)

        // Same bytes as before the teardown -- design §5.3's byte-identity
        // memoization would normally skip a rebuild, but `reset()` cleared
        // `lastBlob` too, so this must rebuild anyway (see
        // ParameterSetFormatDescriptionCache.reset()'s doc comment).
        session.handle(nalData: Data(blob), nalType: 7, isParameterSet: true, hostTime: 2000)
        #expect(session.hasFormatDescription)

        session.handle(nalData: Self.wellFormedSliceNAL, nalType: 1, isParameterSet: false, hostTime: 2001)
        #expect(renderer.enqueuedCount == 1)
    }

    @Test("an externally-reported async decode failure (AVSampleBufferDisplayLayerFailedToDecode) counts toward the same streak")
    func externalFailureCountsTowardStreak() throws {
        let session = DecodeSession()
        let renderer = MockRenderer()
        session.attach(renderer: renderer)
        var teardownCount = 0
        session.onTeardown = { teardownCount += 1 }

        let blob = try ParameterSetSplitterTests.loadBundledFixtureBlob()
        session.handle(nalData: Data(blob), nalType: 7, isParameterSet: true, hostTime: 0)

        for _ in 0..<DecodeSession.maxConsecutiveFailures {
            session.recordExternalFailure(DecodeSessionError.sampleBufferCreationFailed(-1))
        }

        #expect(teardownCount == 1)
        #expect(!session.hasFormatDescription)
    }
}
