import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation
import Combine

// ─────────────────────────────────────────────────────────────────────────
// Task 3.3: decode and display. Turns the raw per-NAL callbacks from
// `HelperClient.onNALUnit` into `CMSampleBuffer`s enqueued on a
// `SampleBufferRendering` (in practice an `AVSampleBufferDisplayLayer`,
// design §5.4), and implements design.md §7's error policy for this task's
// two relevant rows:
//
//   | Corrupt/undecodable NAL | VideoToolbox OSStatus error | drop the
//     sample, keep the session; on 30 consecutive errors, tear down the
//     decode session and wait for the next parameter set |
//   | Packets flowing, no SPS+IDR (8s) | gating state | ... this task's
//     decode session must cleanly do nothing / not crash while waiting for
//     a first parameter set ... |
//
// Threading: not internally synchronized (like `NALFPSCounter`/
// `HelperClient`'s own state, callers are expected to serialize access on
// one queue). In practice that queue is `DispatchQueue.main`, because
// `HelperClient.onNALUnit` -- like every other `HelperClient` public
// closure -- is always delivered there.
// ─────────────────────────────────────────────────────────────────────────

enum DecodeSessionError: Error, Equatable {
    /// No SPS+PPS-derived format description yet (design §7's second row).
    /// Not a "corrupt NAL" failure -- deliberately excluded from the
    /// consecutive-failure counter (see `handle(nalData:...)`).
    case noFormatDescriptionYet
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case attachmentsUnavailable
}

/// Owns the parameter-set cache (Task 3.2) and the running
/// consecutive-decode-failure count (design §7), and builds/enqueues
/// `CMSampleBuffer`s for slice NALs against a `SampleBufferRendering`.
final class DecodeSession: ObservableObject {

    /// design.md §7: "on 30 consecutive errors, tear down the decode
    /// session."
    static let maxConsecutiveFailures = 30

    private let formatCache = ParameterSetFormatDescriptionCache()
    #if canImport(AppKit)
    /// Per-window freeze toggle (see `FreezableDisplayLayer`).
    let freezeState = FreezeState()
    #endif
    private weak var renderer: SampleBufferRendering?
    private var extraConsumers: [WeakConsumer] = []
    private let consumerLock = NSLock()

    private struct WeakConsumer {
        weak var value: SampleBufferRendering?
    }
    /// Real stream size from the SPS, nil until the first parameter set.
    @Published private(set) var dimensions: CMVideoDimensions?
    /// Smoothed delay from the helper stamping a NAL to it being handed to the
    /// display layer (XPC + queueing). Excludes goggles-internal and display time.
    @Published private(set) var latencyMs: Double?
    private var latencyEMA: Double?
    private var lastLatencyPublish: UInt64 = 0
    private(set) var consecutiveFailures = 0
    private(set) var teardownCount = 0

    /// Fired (on whatever queue `handle`/`recordExternalFailure` is called
    /// on) whenever a sample is dropped -- parameter-set parse failure,
    /// AVCC conversion failure, `CMSampleBuffer` construction failure, or an
    /// externally-reported async VideoToolbox decode failure. Not fired for
    /// the "no format description yet" no-op case (that's expected steady
    /// -state while waiting for the first/next parameter set, not an
    /// error).
    var onDroppedSample: ((Error) -> Void)?
    /// Raw NAL observer (research data collection); called before decoding.
    var onRawNAL: ((Data, UInt8, Bool, UInt64) -> Void)?
    /// Fired once per teardown (the 30th consecutive failure).
    var onTeardown: (() -> Void)?

    init() {}

    /// Attaches (or replaces) the render target. Safe to call before any
    /// NAL has been seen, and again later (e.g. `GogglesVideoView` handing
    /// over a freshly-created `AVSampleBufferDisplayLayer` once its host
    /// `NSView` exists).
    func attach(renderer: SampleBufferRendering) {
        self.renderer = renderer
    }

    /// The frame currently on screen in the primary display layer (screenshots).
    func copyDisplayedFrame() -> CVPixelBuffer? {
        guard #available(macOS 14.4, *) else { return nil }
        return (renderer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer.displayedPixelBuffer()
    }

    /// Adds an extra sample-buffer consumer (second display window,
    /// recorder) that receives every slice alongside the primary renderer.
    /// Held weakly, same as the primary.
    func addConsumer(_ consumer: SampleBufferRendering) {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        extraConsumers.removeAll { $0.value == nil || $0.value === consumer }
        extraConsumers.append(WeakConsumer(value: consumer))
    }

    func removeConsumer(_ consumer: SampleBufferRendering) {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        extraConsumers.removeAll { $0.value == nil || $0.value === consumer }
    }

    /// `true` once a parameter set has been decoded and cached -- i.e.
    /// slice NALs will actually be converted/enqueued rather than silently
    /// dropped. Exposed for tests/observability, not required for the
    /// decode path itself.
    var hasFormatDescription: Bool { formatCache.formatDescription != nil }

    /// Entry point: call once per `HelperClient.onNALUnit` callback,
    /// verbatim arguments.
    func handle(nalData: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        onRawNAL?(nalData, nalType, isParameterSet, hostTime)
        if isParameterSet {
            handleParameterSet(nalData)
            return
        }
        do {
            try handleSlice(nalData, hostTime: hostTime)
            recordSuccess()
        } catch DecodeSessionError.noFormatDescriptionYet {
            // Expected while waiting for the first/next parameter set --
            // cleanly do nothing (design §7's second row), not a failure.
        } catch {
            recordFailure(error)
        }
    }

    /// Lets an external observer (the host view's
    /// `AVSampleBufferDisplayLayerFailedToDecode` notification handler --
    /// VideoToolbox's own async decode errors don't surface synchronously
    /// from `enqueue(_:)`) feed into the same §7 counting/teardown policy
    /// as a synchronously-detected failure.
    func recordExternalFailure(_ error: Error) {
        recordFailure(error)
    }

    // MARK: - Parameter sets

    private func handleParameterSet(_ data: Data) {
        do {
            try formatCache.update(withBundledBlob: [UInt8](data))
            if let fd = formatCache.formatDescription {
                let dims = CMVideoFormatDescriptionGetDimensions(fd)
                if dims.width != dimensions?.width || dims.height != dimensions?.height {
                    DispatchQueue.main.async { self.dimensions = dims }
                }
            }
            // A parameter set that parses fine is itself a "things are
            // healthy" signal -- reset the streak so a run of unrelated
            // slice-NAL failures before this point doesn't carry over and
            // trip teardown against a session that just got a good
            // parameter set.
            consecutiveFailures = 0
        } catch {
            // A malformed parameter-set blob doesn't get the slice-NAL
            // teardown treatment -- there's nothing decodable to tear down
            // yet if this was the first one, and if it wasn't, the
            // previously-cached format description (if any) is left alone
            // rather than discarded over one bad blob.
            onDroppedSample?(error)
            Logging.decode.error("parameter-set update failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Slice NALs

    private func handleSlice(_ data: Data, hostTime: UInt64) throws {
        guard let formatDescription = formatCache.formatDescription else {
            throw DecodeSessionError.noFormatDescriptionYet
        }
        let avccData = try NALAnnexBToAVCC.convert(data)
        let sampleBuffer = try DecodeSession.makeSampleBuffer(
            avccData: avccData,
            formatDescription: formatDescription,
            hostTime: hostTime
        )
        try DecodeSession.markDisplayImmediately(sampleBuffer)
        renderer?.enqueue(sampleBuffer)
        recordLatency(hostTime: hostTime)
        consumerLock.lock()
        let extras = extraConsumers.compactMap { $0.value }
        consumerLock.unlock()
        for consumer in extras { consumer.enqueue(sampleBuffer) }
    }

    // MARK: - Latency

    static func milliseconds(fromNanoseconds ns: UInt64) -> Double {
        Double(ns) / 1_000_000
    }

    /// `hostTime` is `DispatchTime.now().uptimeNanoseconds` stamped by the
    /// helper (nanoseconds, NOT mach ticks), same clock as in this process.
    private func recordLatency(hostTime: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= hostTime else { return }
        let ms = DecodeSession.milliseconds(fromNanoseconds: now - hostTime)
        latencyEMA = latencyEMA.map { $0 * 0.9 + ms * 0.1 } ?? ms
        guard DecodeSession.milliseconds(fromNanoseconds: now &- lastLatencyPublish) >= 500,
              let value = latencyEMA else { return }
        lastLatencyPublish = now
        DispatchQueue.main.async { self.latencyMs = value }
    }

    // MARK: - CMSampleBuffer construction

    /// Wraps AVCC-converted bytes in a `CMBlockBuffer`, then a
    /// `CMSampleBuffer`, timestamped from the helper's `hostTime`
    /// (uptime nanoseconds).
    static func makeSampleBuffer(
        avccData: Data,
        formatDescription: CMVideoFormatDescription,
        hostTime: UInt64
    ) throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(from: avccData)

        // design §5.4: "does not attempt a presentation clock" -- the PTS
        // below exists because `CMSampleBufferCreateReady` requires valid
        // timing info, not because anything downstream schedules against
        // it; `DisplayImmediately` (set below) is what actually governs
        // when the layer shows the frame.
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime(forHostTime: hostTime),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleSizes = [avccData.count]
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DecodeSessionError.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }

    private static func makeBlockBuffer(from avccData: Data) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecodeSessionError.blockBufferCreationFailed(createStatus)
        }
        let copyStatus = avccData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw DecodeSessionError.blockBufferCreationFailed(copyStatus)
        }
        return blockBuffer
    }

    /// design §5.4's `kCMSampleAttachmentKey_DisplayImmediately = true`,
    /// set on the (sole) sample's attachments dictionary.
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) throws {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
              let attachments = attachmentsArray.first else {
            throw DecodeSessionError.attachmentsUnavailable
        }
        CFDictionarySetValue(
            attachments,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// The helper stamps frames with `DispatchTime.now().uptimeNanoseconds`,
    /// so `hostTime` is already nanoseconds (not mach ticks).
    private static func presentationTime(forHostTime hostTime: UInt64) -> CMTime {
        CMTime(value: Int64(clamping: hostTime), timescale: 1_000_000_000)
    }

    // MARK: - §7 error-policy bookkeeping

    private func recordSuccess() {
        consecutiveFailures = 0
    }

    private func recordFailure(_ error: Error) {
        consecutiveFailures += 1
        Logging.decode.error("dropped sample (\(self.consecutiveFailures, privacy: .public)/\(DecodeSession.maxConsecutiveFailures, privacy: .public) consecutive): \(String(describing: error), privacy: .public)")
        onDroppedSample?(error)
        if consecutiveFailures >= DecodeSession.maxConsecutiveFailures {
            tearDown()
        }
    }

    private func tearDown() {
        Logging.decode.fault("\(DecodeSession.maxConsecutiveFailures, privacy: .public) consecutive decode failures -- tearing down decode session, waiting for next parameter set")
        formatCache.reset()
        renderer?.flush()
        consecutiveFailures = 0
        teardownCount += 1
        onTeardown?()
    }
}
