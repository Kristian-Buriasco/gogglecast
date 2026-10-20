import Testing
import AVFoundation
@testable import GogglesView

private final class CountingLayer: AVSampleBufferDisplayLayer {
    private(set) var count = 0
    override func enqueue(_ sampleBuffer: CMSampleBuffer) { count += 1 }
}

@Suite struct PreviewPolicyTests {
    @Test func previewOffOnlyWhenHdmiOnlyAndOutputsShown() {
        #expect(PreviewPolicy.previewActive(hdmiOnly: false, outputsShown: false))
        #expect(PreviewPolicy.previewActive(hdmiOnly: false, outputsShown: true))
        #expect(PreviewPolicy.previewActive(hdmiOnly: true, outputsShown: false), "no output on screen: never leave nothing visible")
        #expect(!PreviewPolicy.previewActive(hdmiOnly: true, outputsShown: true))
    }

    @Test func stateFollowsOutputsClosing() {
        let s = PreviewState()
        s.update(hdmiOnly: true, outputsShown: true)
        #expect(!s.isActive)
        s.update(hdmiOnly: true, outputsShown: false)
        #expect(s.isActive)
    }

    @Test func inactivePreviewSkipsPreviewLayersButFeedsProgram() {
        var active = false
        let session = DecodeSession()
        session.isPreviewActive = { active }
        let primary = CountingLayer(), preview = CountingLayer(), program = CountingLayer()
        session.attach(renderer: primary)
        session.addConsumer(preview)
        session.addConsumer(program, program: true)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)

        session.injectDecodedFrame(pb!)
        #expect(primary.count == 0 && preview.count == 0 && program.count == 1)

        active = true
        session.injectDecodedFrame(pb!)
        #expect(primary.count == 1 && preview.count == 1 && program.count == 2)
    }
}
