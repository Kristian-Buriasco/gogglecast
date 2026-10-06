import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum NDIPrefs {
    static let libraryPathKey = "ndiLibraryPath"
    static let sourceNameKey = "ndiSourceName"
    static let unverifiedAckKey = "ndiAcceptUnverifiedABI"

    static var libraryPath: String? { UserDefaults.standard.string(forKey: libraryPathKey) }
    static var sourceName: String { clampName(UserDefaults.standard.string(forKey: sourceNameKey)) }
    static var acceptedUnverified: Bool { UserDefaults.standard.bool(forKey: unverifiedAckKey) }

    static func clampName(_ n: String?) -> String {
        let t = n?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "GogglesView" : String(t.prefix(128))
    }
}

/// UNVERIFIED ABI: these layouts are written from memory of the public NDI SDK
/// (Processing.NDI.structs.h / Send.h) and have NOT been checked against the
/// real headers on a machine with the SDK. Before relying on this, verify against
/// the header: field order/types of NDIlib_send_create_t and NDIlib_video_frame_v2_t,
/// the FourCC for UYVY ('UYVY' little-endian), frame_format_type progressive == 1,
/// NDIlib_send_send_video_v2 / NDIlib_send_create / NDIlib_initialize signatures,
/// and the "frame must stay valid until the next send call" async rule.
enum NDIABI {
    struct SendCreate { // NDIlib_send_create_t
        var p_ndi_name: UnsafePointer<CChar>?
        var p_groups: UnsafePointer<CChar>?
        var clock_video: Bool
        var clock_audio: Bool
    }
    struct VideoFrameV2 { // NDIlib_video_frame_v2_t
        var xres: Int32 = 0
        var yres: Int32 = 0
        var FourCC: UInt32 = 0
        var frame_rate_N: Int32 = 30000
        var frame_rate_D: Int32 = 1001
        var picture_aspect_ratio: Float = 0 // 0 = square pixels from xres/yres
        var frame_format_type: Int32 = 1    // NDIlib_frame_format_type_progressive
        var timecode: Int64 = Int64.max     // NDIlib_send_timecode_synthesize
        var p_data: UnsafeMutableRawPointer?
        var line_stride_in_bytes: Int32 = 0 // union with data_size_in_bytes
        var p_metadata: UnsafePointer<CChar>?
        var timestamp: Int64 = 0
    }
    static let fourCCUYVY: UInt32 = 0x59565955 // 'U','Y','V','Y' little-endian
    /// Sizes expected from the C headers on 64-bit macOS (checked by tests as a tripwire only).
    static let expectedSendCreateSize = 24
    static let expectedVideoFrameSize = 72
}

/// Decodes the passthrough H.264 to UYVY and hands frames to NDI (async send),
/// loaded entirely via dlopen. See `NDIABI` for the unverified-ABI caveat.
final class NDIOutput: ObservableObject, SampleBufferRendering {
    @Published private(set) var isStreaming = false
    @Published private(set) var framesSent: UInt64 = 0
    @Published private(set) var lastError: String?

    init() {
        OutputActivityBoard.shared.register(self) { [weak self] in self?.isStreaming == true }
    }
    deinit { OutputActivityBoard.shared.unregister(self) }

    private typealias FnInit = @convention(c) () -> Bool
    private typealias FnVoid = @convention(c) () -> Void
    private typealias FnCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FnSendVideo = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void

    static let symbols = ["NDIlib_initialize", "NDIlib_destroy", "NDIlib_send_create",
                          "NDIlib_send_destroy", "NDIlib_send_send_video_v2"]

    private let queue = DispatchQueue(label: "NDIOutput")
    private var handle: UnsafeMutableRawPointer?
    private var destroyLib: FnVoid?
    private var sendDestroy: FnDestroy?
    private var sendVideo: FnSendVideo?
    private var instance: UnsafeMutableRawPointer?
    private var nameC: UnsafeMutablePointer<CChar>?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var held: CVPixelBuffer?   // previous frame; NDI async send needs it alive until the next send
    private var lastPTS: Double?
    private var fps: Int32 = 30
    private var active = false
    private var frames: UInt64 = 0

    static func isAvailable() -> Bool { OutputLibrary.resolveNDI() != nil }

    func start(sourceName: String) {
        guard !isStreaming else { return }
        guard NDIPrefs.acceptedUnverified else { fail("NDI send path is unverified; enable the experimental toggle first"); return }
        guard let path = OutputLibrary.resolveNDI() else { fail("NDI runtime not found"); return }
        guard let lib = OutputLibrary.open(path, symbols: Self.symbols) else { fail("NDI runtime could not be loaded or lacks required symbols"); return }
        let initialize = unsafeBitCast(lib.fns["NDIlib_initialize"]!, to: FnInit.self)
        guard initialize() else { fail("NDIlib_initialize failed (unsupported CPU?)"); dlclose(lib.handle); return }
        let create = unsafeBitCast(lib.fns["NDIlib_send_create"]!, to: FnCreate.self)
        let name = strdup(NDIPrefs.clampName(sourceName))
        var desc = NDIABI.SendCreate(p_ndi_name: UnsafePointer(name), p_groups: nil, clock_video: false, clock_audio: false)
        guard let inst = create(&desc) else {
            free(name); unsafeBitCast(lib.fns["NDIlib_destroy"]!, to: FnVoid.self)(); dlclose(lib.handle)
            fail("NDIlib_send_create failed"); return
        }
        queue.sync {
            handle = lib.handle; instance = inst; nameC = name
            destroyLib = unsafeBitCast(lib.fns["NDIlib_destroy"]!, to: FnVoid.self)
            sendDestroy = unsafeBitCast(lib.fns["NDIlib_send_destroy"]!, to: FnDestroy.self)
            sendVideo = unsafeBitCast(lib.fns["NDIlib_send_send_video_v2"]!, to: FnSendVideo.self)
            lastPTS = nil; frames = 0; active = true
        }
        isStreaming = true; lastError = nil; framesSent = 0
    }

    func stop() {
        queue.async { [self] in
            guard active else { return }
            active = false
            if let s = session { VTDecompressionSessionInvalidate(s) }
            session = nil; sessionFormat = nil
            // Destroying the sender flushes the pending async frame; only then release the buffer.
            sendDestroy?(instance); instance = nil
            if let h = held { CVPixelBufferUnlockBaseAddress(h, .readOnly) }
            held = nil
            destroyLib?()
            if let h = handle { dlclose(h) }
            handle = nil; sendVideo = nil; sendDestroy = nil; destroyLib = nil
            if let n = nameC { free(n); nameC = nil }
            DispatchQueue.main.async { self.isStreaming = false }
        }
    }

    private func fail(_ msg: String) { lastError = msg; isStreaming = false }

    // MARK: decode

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard active, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            if session == nil || !(sessionFormat.map { CFEqual($0, fd) } ?? false) {
                guard makeSession(fd) else { return }
            }
            guard let session else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if let last = lastPTS, pts > last { fps = (pts - last) < 0.025 ? 60 : 30 }
            lastPTS = pts
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) {
                [weak self] status, _, image, _, _ in
                guard status == noErr, let image else { return }
                self?.queue.async { self?.send(image) }
            }
        }
    }

    private func makeSession(_ fd: CMFormatDescription) -> Bool {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8, // '2vuy' == NDI UYVY
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                              decompressionSessionOut: &s)
        guard st == noErr, let s else {
            DispatchQueue.main.async { self.lastError = "Decoder setup failed (\(st))" }
            return false
        }
        session = s; sessionFormat = fd
        return true
    }

    private func send(_ pb: CVPixelBuffer) {
        guard active, let instance, let sendVideo else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        var frame = NDIABI.VideoFrameV2()
        frame.xres = Int32(CVPixelBufferGetWidth(pb)); frame.yres = Int32(CVPixelBufferGetHeight(pb))
        frame.FourCC = NDIABI.fourCCUYVY
        frame.frame_rate_N = fps * 1000; frame.frame_rate_D = 1000
        frame.p_data = CVPixelBufferGetBaseAddress(pb)
        frame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(pb))
        sendVideo(instance, &frame)
        // The previous frame is now free to release (NDI holds only the latest).
        if let old = held { CVPixelBufferUnlockBaseAddress(old, .readOnly) }
        held = pb
        frames += 1
        let n = frames
        if n % 30 == 0 { DispatchQueue.main.async { self.framesSent = n } }
    }

    func flush() {}
}
