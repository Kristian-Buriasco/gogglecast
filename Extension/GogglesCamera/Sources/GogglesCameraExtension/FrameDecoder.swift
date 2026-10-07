import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import GogglesH264

/// Decodes the helper's H.264 NAL units into pixel buffers. Same approach as the app's
/// `DecodeSession`: cache SPS/PPS, convert slices to AVCC, wait for an IDR before decoding.
/// Not thread-safe; `HelperFeed` calls it from one queue.
final class FrameDecoder {
    /// Called on a VideoToolbox thread with each decoded picture.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private static let maxConsecutiveFailures = 30

    private let formatCache = ParameterSetFormatDescriptionCache()
    private var session: VTDecompressionSession?
    private var sessionReady = false
    private var consecutiveFailures = 0

    deinit { invalidate() }

    func handle(nalData: Data, isParameterSet: Bool) {
        if isParameterSet {
            do {
                try formatCache.update(withBundledBlob: [UInt8](nalData))
                consecutiveFailures = 0
            } catch {
                Logging.decode.error("parameter-set update failed: \(String(describing: error), privacy: .public)")
            }
            return
        }
        guard let format = formatCache.formatDescription else { return }
        do {
            let avcc = try NALAnnexBToAVCC.convert(nalData)
            let sample = try Self.makeSampleBuffer(avcc: avcc, format: format)
            decode(sample, avcc: avcc, format: format)
        } catch {
            recordFailure(error)
        }
    }

    /// Drops the decoder so the next stream starts clean (stream stop, helper restart).
    func reset() {
        invalidate()
        formatCache.reset()
        consecutiveFailures = 0
    }

    // MARK: - Decoding

    private func decode(_ sample: CMSampleBuffer, avcc: Data, format: CMVideoFormatDescription) {
        if let s = session, !VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: format) {
            invalidate()
        }
        if session == nil { createSession(format) }
        guard let session else { return }
        if !sessionReady {
            // Joining mid-stream would only produce grey; wait for a real IDR.
            guard Self.containsIDR(avcc: avcc) else { return }
            sessionReady = true
        }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(image)
        }
        if status != noErr { recordFailure(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
    }

    private func createSession(_ format: CMVideoFormatDescription) {
        var s: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let st = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else {
            Logging.decode.error("decoder create failed (\(st, privacy: .public))")
            return
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        sessionReady = false
    }

    private func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        sessionReady = false
    }

    private func recordFailure(_ error: Error) {
        consecutiveFailures += 1
        Logging.decode.error("dropped sample (\(self.consecutiveFailures, privacy: .public)): \(String(describing: error), privacy: .public)")
        if consecutiveFailures >= Self.maxConsecutiveFailures {
            Logging.decode.fault("too many consecutive decode failures, waiting for next parameter set")
            reset()
        }
    }

    // MARK: - Helpers

    private static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return sample
    }

    /// True if any 4-byte-length-prefixed NAL is an IDR slice (type 5).
    private static func containsIDR(avcc: Data) -> Bool {
        let bytes = [UInt8](avcc)
        var i = 0
        while i + 4 < bytes.count {
            let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let h = i + 4
            guard len > 0, h < bytes.count else { break }
            if bytes[h] & 0x1F == 5 { return true }
            i = h + len
        }
        return false
    }
}
