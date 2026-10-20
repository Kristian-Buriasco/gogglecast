import Testing
import CoreMedia
import CoreVideo
import Foundation
@testable import GogglesView

/// A display layer that never drains: holds at most `capacity` samples, like a full AVSampleBufferDisplayLayer queue.
final class SlowRenderer: SampleBufferRendering {
    let capacity = 2
    private(set) var pending: [CMSampleBuffer] = []
    private(set) var maxPending = 0
    var wantsDecodedPictures: Bool { true }
    var isReadyForMoreMediaData: Bool { pending.count < capacity }
    func enqueue(_ sampleBuffer: CMSampleBuffer) { pending.append(sampleBuffer); maxPending = max(maxPending, pending.count) }
    func flush() { pending.removeAll() }
}

@Suite("DecodeSession newest frame wins")
struct NewestFrameWinsTests {
    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    @Test("a layer that never drains holds at most 2 samples and ends on the newest")
    func slowConsumerKeepsNewest() {
        let session = DecodeSession()
        let layer = SlowRenderer()
        session.attach(renderer: layer)
        var last: CVPixelBuffer?
        for _ in 0..<50 { last = makePixelBuffer(); session.injectDecodedFrame(last!) }
        #expect(layer.maxPending <= 2)
        #expect(session.latencyDroppedCount > 0)
        #expect(session.decodedSequence() == 50)
        let shown = layer.pending.last.flatMap { CMSampleBufferGetImageBuffer($0) }
        #expect(shown === last)
    }

    @Test("a layer that keeps up is never flushed or counted as a drop")
    func fastConsumerUntouched() {
        let session = DecodeSession()
        let slow = SlowRenderer()
        session.attach(renderer: slow)
        for _ in 0..<2 { session.injectDecodedFrame(makePixelBuffer()) }
        #expect(slow.pending.count == 2)
        #expect(session.latencyDroppedCount == 0)
    }

    @Test("only a picture with newer ones waiting behind it and over the age limit is stale")
    func staleRule() {
        #expect(!DecodeSession.isStale(ageMs: 500, newerPending: 0)) // newest in the pipeline always shows
        #expect(!DecodeSession.isStale(ageMs: 20, newerPending: 3))  // fresh enough
        #expect(DecodeSession.isStale(ageMs: 150, newerPending: 1))
    }
}
