import Foundation
import CoreGraphics
import CoreText
import CoreMedia
import CoreVideo
import VideoToolbox

/// Turns decoded pictures (any size, NV12) into 1920x1080 BGRA sample buffers for the CMIO stream,
/// and draws the "no signal" card shown while the goggles are absent.
final class FrameRenderer {
    static let width = 1920
    static let height = 1080

    private var pool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var noSignalCache: [String: CVPixelBuffer] = [:]

    init() {
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        if let transfer {
            // Keep the picture's aspect ratio inside the fixed output size.
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        }
    }

    /// Converts and scales `source` into a pooled output buffer.
    func render(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, let transfer, let out = makeOutputBuffer(from: pool) else { return nil }
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: out)
        return status == noErr ? out : nil
    }

    /// A static explanatory card. Cached per message since the text rarely changes.
    func noSignal(message: String) -> CVPixelBuffer? {
        if let cached = noSignalCache[message] { return cached }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Self.width, height: Self.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        draw(text: "DJI Goggles 3", size: 72, y: 560, in: ctx, white: 1.0)
        draw(text: message, size: 40, y: 470, in: ctx, white: 0.65)
        noSignalCache[message] = buffer
        return buffer
    }

    /// Wraps a pixel buffer as a sample buffer stamped with `hostTimeNs` (the CMIO host clock).
    func sampleBuffer(for pixelBuffer: CVPixelBuffer, hostTimeNs: UInt64, frameDuration: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMTime(value: Int64(clamping: hostTimeNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func makeOutputBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        // Letterbox leaves the margins untouched, so start from black.
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(out) * CVPixelBufferGetHeight(out))
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    private func draw(text: String, size: CGFloat, y: CGFloat, in ctx: CGContext, white: CGFloat) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: white, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(Self.width) - bounds.width) / 2, y: y)
        CTLineDraw(line, ctx)
    }
}
