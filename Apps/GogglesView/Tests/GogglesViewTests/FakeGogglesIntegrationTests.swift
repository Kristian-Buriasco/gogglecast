import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
import VideoToolbox
@testable import GogglesView

// End-to-end scenarios driven by `FakeGoggles`, a software source that mimics the real goggles
// (one IDR, then P frames only, SPS+PPS ~5 times a second, 1920x1080 at ~60 fps).
//
// Set GOGGLES_SKIP_SLOW_TESTS=1 to skip the longest scenarios (framing, LUT, stabilizer, silence).
// Timing thresholds are deliberately loose: CI runs on a slow virtual machine.

extension Tag { @Tag static var fakeGoggles: Self; @Tag static var slow: Self }

private let skipSlow = ProcessInfo.processInfo.environment["GOGGLES_SKIP_SLOW_TESTS"] != nil

// MARK: - Harness

private let touchedDefaults: [String] = [
    OutputFramingPrefs.enabledKey, OutputFramingPrefs.aspectKey, OutputFramingPrefs.zoomKey,
    OutputFramingPrefs.panXKey, OutputFramingPrefs.panYKey,
    LookPrefs.nameKey, LookPrefs.intensityKey, LookPrefs.previewKey, LookPrefs.outputKey,
    StabilizerPrefs.enabledKey, StabilizerPrefs.strengthKey,
    ReencodePrefs.enabledKey, ReencodePrefs.bitrateKey,
    ReplayPrefs.enabledKey, ReplayPrefs.secondsKey,
    RecordingPrefs.folderKey, RecordingPrefs.containerKey, RecordingPrefs.prefixKey, RaceModePrefs.key,
]

/// One session + one fake source + a temp folder, with every changed default put back afterwards.
private final class Rig {
    let session = DecodeSession()
    let fake: FakeGoggles
    let dir: URL
    private let savedDefaults: [String: Any]
    private let savedLUTDirectory = LUTLibrary.directory

    init(_ options: FakeGoggles.Options = .init()) {
        let d = UserDefaults.standard
        var saved: [String: Any] = [:]
        for k in touchedDefaults { if let v = d.object(forKey: k) { saved[k] = v } }
        savedDefaults = saved
        for k in touchedDefaults { d.removeObject(forKey: k) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakegoggles-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        d.set(dir.path, forKey: RecordingPrefs.folderKey)
        LUTLibrary.directory = dir.appendingPathComponent("LUTs", isDirectory: true)
        fake = FakeGoggles(session: session, options: options)
    }

    func teardown() {
        fake.stop()
        let d = UserDefaults.standard
        for k in touchedDefaults { d.removeObject(forKey: k) }
        for (k, v) in savedDefaults { d.set(v, forKey: k) }
        LUTLibrary.directory = savedLUTDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    /// Mirrors `GogglesConnectionView.startRecording`.
    func makeRecorder(name: String, metadata: (() -> ClipRecordInfo?)? = nil) throws -> (Recorder, URL) {
        let recorder = Recorder()
        session.addConsumer(recorder)
        recorder.keyframeHub = session.reencodeHub
        recorder.metadataProvider = metadata
        recorder.capacityProvider = { _ in 100_000_000_000 }   // the host disk is not what is under test
        let url = dir.appendingPathComponent("\(name).mov")
        try recorder.start(to: url)
        return (recorder, url)
    }

    /// Mirrors `GogglesConnectionView.stopRecording`.
    func finish(_ recorder: Recorder) async -> URL? {
        session.removeConsumer(recorder)
        return await withCheckedContinuation { c in recorder.stop { c.resume(returning: $0) } }
    }

    /// Waits for the re-encoder to go idle so the next recording starts from a clean output stage.
    func waitHubIdle() async {
        _ = await waitUntil(5) { self.session.reencodeHub.subscriberCount == 0 }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}

private func withRig(_ options: FakeGoggles.Options = .init(), _ body: (Rig) async throws -> Void) async throws {
    let rig = Rig(options)
    do { try await body(rig) } catch { rig.teardown(); throw error }
    rig.teardown()
}

@discardableResult
private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

/// Starts the fake and waits until the display decoder has produced its first picture.
private func startAndWaitForPicture(_ rig: Rig) async throws {
    try rig.fake.start()
    let ok = await waitUntil(10) { rig.session.latestDecodedFrame() != nil }
    #expect(ok, "no decoded picture within 10 s")
}

// MARK: - Media inspection

private struct ClipInfo { var duration: Double; var tracks: Int; var size: CGSize; var playable: Bool }

private func inspect(_ url: URL) async throws -> ClipInfo {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let playable = try await asset.load(.isPlayable)
    let size = try await tracks.first?.load(.naturalSize) ?? .zero
    return ClipInfo(duration: CMTimeGetSeconds(duration), tracks: tracks.count, size: size, playable: playable)
}

private func frame(of url: URL, at seconds: Double) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    return try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

private struct ImageStats { var r: Double; var g: Double; var b: Double; var lumaStdDev: Double }

/// Mean colour (0...255) and luma spread of an image, from a 96x54 downscale.
private func stats(_ image: CGImage) -> ImageStats {
    let w = 96, h = 54
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var r = 0.0, g = 0.0, b = 0.0, lumas: [Double] = []
    for i in 0..<(w * h) {
        let pr = Double(px[i * 4]), pg = Double(px[i * 4 + 1]), pb = Double(px[i * 4 + 2])
        r += pr; g += pg; b += pb
        lumas.append(0.2126 * pr + 0.7152 * pg + 0.0722 * pb)
    }
    let n = Double(w * h)
    let mean = lumas.reduce(0, +) / n
    let variance = lumas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
    return ImageStats(r: r / n, g: g / n, b: b / n, lumaStdDev: variance.squareRoot())
}

/// Collects what a keyframe-safe consumer is handed.
private final class Collector: SampleBufferRendering {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var keys: [Bool] = []
    private(set) var firstAt: Date?
    var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }
    var keyflags: [Bool] { lock.lock(); defer { lock.unlock() }; return keys }
    func first(_ n: Int) -> [CMSampleBuffer] { lock.lock(); defer { lock.unlock() }; return Array(samples.prefix(n)) }
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        if firstAt == nil { firstAt = Date() }
        if samples.count < 30 { samples.append(sampleBuffer) }
        keys.append(Recorder.isKeyframe(sampleBuffer))
    }
    func flush() {}
}

/// Decodes `samples` in order with a fresh VideoToolbox session; returns the picture count and size.
private func decodeAll(_ samples: [CMSampleBuffer]) -> (decoded: Int, size: CGSize) {
    guard let fmt = samples.first.flatMap({ CMSampleBufferGetFormatDescription($0) }) else { return (0, .zero) }
    var s: VTDecompressionSession?
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                       imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s) == noErr,
          let s else { return (0, .zero) }
    final class Box { var n = 0; var size = CGSize.zero }
    let box = Box()
    for sample in samples {
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            box.n += 1
            box.size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(s)
    VTDecompressionSessionInvalidate(s)
    return (box.n, box.size)
}

private func tempFile(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString).\(ext)")
}

// MARK: - Tests

@Suite(.serialized, .tags(.fakeGoggles))
struct FakeGogglesIntegrationTests {

    // (a) The display decoder starts on the single IDR and keeps producing pictures.
    @MainActor @Test func displayDecoderProducesFramesAfterTheSingleIDR() async throws {
        try await withRig { rig in
            let layer = AVSampleBufferDisplayLayer()
            rig.session.attach(renderer: layer)
            try await startAndWaitForPicture(rig)
            await sleep(1.5)
            #expect(rig.fake.idrDelivered == 1, "the fake must behave like the goggles: exactly one IDR")
            #expect(rig.fake.parameterSetsDelivered >= 4, "SPS/PPS repeat about 5 times a second")
            let first = rig.session.latestDecodedFrame()
            #expect(first != nil)
            #expect(first.map { CVPixelBufferGetWidth($0) } == 1920)
            #expect(first.map { CVPixelBufferGetHeight($0) } == 1080)
            #expect(rig.session.hasRecentPicture(within: 1))
            #expect(rig.session.isWaitingForKeyframe == false)
            await sleep(0.3)
            let second = rig.session.latestDecodedFrame()
            #expect(second != nil && second !== first, "pictures keep coming after the IDR")
            #expect(rig.session.hasFormatDescription)
            #expect(rig.session.dimensions?.width == 1920 && rig.session.dimensions?.height == 1080)
            #expect(rig.session.teardownCount == 0)
            #expect(layer.status != .failed, "display layer failed: \(String(describing: layer.error))")
        }
    }

    // (b) A keyframe-safe consumer that joins long after the IDR still gets a decodable stream.
    @Test func lateJoiningKeyframeSafeConsumerGetsADecodableStream() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            await sleep(2)
            let c = Collector()
            let joined = Date()
            rig.fake.joinLate(consumer: c, on: rig.session)
            let got = await waitUntil(8) { c.count >= 10 }
            #expect(got, "got only \(c.count) samples")
            defer { rig.session.removeConsumer(c) }
            let first = try #require(c.firstAt)
            #expect(first.timeIntervalSince(joined) < 3, "first sample took \(first.timeIntervalSince(joined)) s")
            #expect(c.keyflags.first == true, "the first sample a late joiner sees must be a keyframe")
            let result = decodeAll(c.first(10))
            #expect(result.decoded >= 9, "decoded \(result.decoded) of 10")
            #expect(result.size == CGSize(width: 1920, height: 1080))
            // Keyframes keep coming about once a second.
            await sleep(2.5)
            #expect(c.keyflags.filter { $0 }.count >= 2)
        }
    }

    // (c) Recording armed after the IDR (mid-stream) falls back to the re-encoded stream.
    @Test func recordingArmedAfterTheIDRIsPlayable() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            await sleep(1)
            let (rec, url) = try rig.makeRecorder(name: "late")
            await sleep(5)
            let out = await rig.finish(rec)
            #expect(out == url)
            let info = try await inspect(url)
            #expect(info.playable)
            #expect(info.tracks == 1)
            #expect(info.size == CGSize(width: 1920, height: 1080))
            #expect(info.duration > 1, "duration \(info.duration)")
            let img = try await frame(of: url, at: 0)
            #expect(img.width == 1920 && img.height == 1080)
            #expect(stats(img).lumaStdDev > 5, "first frame looks flat")
            _ = try await frame(of: url, at: max(0, info.duration - 0.5))
            #expect(rec.failure == nil)
        }
    }

    // (d) Recording armed before the IDR is passthrough.
    @Test func recordingArmedBeforeTheIDRIsPassthroughAndPlayable() async throws {
        try await withRig { rig in
            let (rec, url) = try rig.makeRecorder(name: "early")
            try await startAndWaitForPicture(rig)
            await sleep(4)
            #expect(rig.session.reencodeHub.subscriberCount == 0, "passthrough must not need the re-encoder")
            _ = await rig.finish(rec)
            let info = try await inspect(url)
            #expect(info.playable)
            #expect(info.tracks == 1)
            #expect(info.size == CGSize(width: 1920, height: 1080))
            #expect(info.duration > 2, "duration \(info.duration)")
            do {
                let img = try await frame(of: url, at: 0)
                #expect(stats(img).lumaStdDev > 5)
            } catch { Issue.record("first frame of passthrough file not decodable: \(error)") }
            // The P-frame chain after the single IDR must decode too, not just the first picture.
            // (AVAssetImageGenerator is not used for late frames: it fails with -12911 on a single-keyframe
            // file of this length although AVAssetReader decodes every frame.)
            let decoded = try await decodedFrameCount(url)
            #expect(Double(decoded) > info.duration * 40, "decoded only \(decoded) frames of \(info.duration) s")
            #expect(rec.failure == nil)
        }
    }

    // (e) UDP MPEG-TS output.
    @Test func udpStreamerSendsMPEGTS() async throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        try #require(sock >= 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var rcvbuf: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        final class Capture: @unchecked Sendable {
            let lock = NSLock(); var data = Data(); var datagrams = 0; var stop = false
            func finish() -> (Data, Int) { lock.lock(); defer { lock.unlock() }; stop = true; return (data, datagrams) }
        }
        let cap = Capture()
        let reader = Thread {
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                cap.lock.lock(); let s = cap.stop; cap.lock.unlock()
                if s { return }
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 { cap.lock.lock(); cap.data.append(contentsOf: buf[0..<n]); cap.datagrams += 1; cap.lock.unlock() }
            }
        }
        reader.start()

        try await withRig { rig in
            let streamer = NetworkStreamer()
            try await startAndWaitForPicture(rig)
            rig.session.addKeyframeSafeConsumer(streamer)
            streamer.start(host: "127.0.0.1", port: port)
            await sleep(5)
            rig.session.removeConsumer(streamer)
            streamer.stop()
            await sleep(0.3)
        }
        let (data, datagrams) = cap.finish()

        #expect(datagrams > 20, "only \(datagrams) datagrams")
        #expect(data.count > 100_000)
        #expect(data.count % 188 == 0, "datagrams must carry whole TS packets")
        let packets = data.count / 188
        let bad = (0..<packets).filter { data[$0 * 188] != 0x47 }.count
        #expect(bad == 0, "\(bad) of \(packets) packets lack the 0x47 sync byte")

        let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffprobe else {
            print("ffprobe not installed; TS content was not verified beyond sync bytes")
            return
        }
        let file = tempFile("ts"); defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", file.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.hasPrefix("h264,1920,1080"), "ffprobe said: \(text)")
    }

    // (f) Output framing crops what leaves the app.
    @Test(.tags(.slow), .enabled(if: !skipSlow)) func outputFramingSetsTheRecordedDimensions() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            let d = UserDefaults.standard
            d.set(true, forKey: OutputFramingPrefs.enabledKey)
            for (aspect, expected) in [(FramingAspect.r1x1, CGSize(width: 1080, height: 1080)),
                                       (FramingAspect.r9x16, CGSize(width: 606, height: 1080))] {
                d.set(aspect.rawValue, forKey: OutputFramingPrefs.aspectKey)
                let (rec, url) = try rig.makeRecorder(name: aspect.rawValue)
                await sleep(3.5)
                _ = await rig.finish(rec)
                let info = try await inspect(url)
                #expect(info.playable)
                #expect(info.size == expected, "\(aspect.rawValue): got \(info.size)")
                #expect(info.duration > 1, "\(aspect.rawValue): duration \(info.duration)")
                let img = try await frame(of: url, at: 0.5)
                #expect(img.width == Int(expected.width) && img.height == Int(expected.height))
                await rig.waitHubIdle()
            }
        }
    }

    // (g) A LUT applied to the output changes the recorded colours.
    @Test(.tags(.slow), .enabled(if: !skipSlow)) func outputLUTChangesRecordedColours() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            // Plain reference.
            let (r0, plainURL) = try rig.makeRecorder(name: "plain")
            await sleep(3.5)
            _ = await rig.finish(r0)
            await rig.waitHubIdle()
            // Invert LUT (size 2, red fastest).
            try FileManager.default.createDirectory(at: LUTLibrary.directory, withIntermediateDirectories: true)
            var cube = "TITLE \"invert\"\nLUT_3D_SIZE 2\n"
            for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r).0 \(1 - g).0 \(1 - b).0\n" } } }
            try cube.write(to: LUTLibrary.directory.appendingPathComponent("invert.cube"), atomically: true, encoding: .utf8)
            let d = UserDefaults.standard
            d.set("invert", forKey: LookPrefs.nameKey)
            d.set(1.0, forKey: LookPrefs.intensityKey)
            d.set(true, forKey: LookPrefs.outputKey)
            #expect(OutputProcessor.isActive)
            let (r1, lutURL) = try rig.makeRecorder(name: "invert")
            await sleep(3.5)
            _ = await rig.finish(r1)

            let plain = stats(try await frame(of: plainURL, at: 1))
            let inverted = stats(try await frame(of: lutURL, at: 1))
            let diff = abs(plain.r - inverted.r) + abs(plain.g - inverted.g) + abs(plain.b - inverted.b)
            #expect(diff > 150, "mean colour barely changed: plain \(plain) vs inverted \(inverted)")
            // The scene is only locally different between the two takes, so the means should mirror each other.
            for (a, b) in [(plain.r, inverted.r), (plain.g, inverted.g), (plain.b, inverted.b)] {
                #expect(abs((255 - a) - b) < 45, "channel \(a) -> \(b) is not an inversion")
            }
            #expect(inverted.lumaStdDev > 5)
        }
    }

    // (h) The stabilizer lowers the shake that is left in the recording.
    @Test(.tags(.slow), .enabled(if: !skipSlow)) func stabilizerReducesRecordedShake() async throws {
        var o = FakeGoggles.Options()
        o.shake = true
        o.fps = 30   // the stabilizer has a per-frame time budget; keep the debug build on a loaded machine within it
        try await withRig(o) { rig in
            try await startAndWaitForPicture(rig)
            await sleep(1)
            let (r0, offURL) = try rig.makeRecorder(name: "unstabilized")
            await sleep(4.5)
            _ = await rig.finish(r0)
            await rig.waitHubIdle()

            UserDefaults.standard.set(true, forKey: StabilizerPrefs.enabledKey)
            UserDefaults.standard.set(0.8, forKey: StabilizerPrefs.strengthKey)
            #expect(OutputProcessor.needsReencodedStream, "the stabilizer must force the recorder onto the hub")
            await sleep(1)
            let (r1, onURL) = try rig.makeRecorder(name: "stabilized")
            await sleep(4.5)
            let bypassed = rig.session.stabilizerBypassed
            _ = await rig.finish(r1)
            if bypassed { try Test.cancel("stabilizer bypassed itself (machine too slow for 1080p60); reduction not measurable") }

            let off = try await meanMotion(offURL)
            let on = try await meanMotion(onURL)
            #expect(off > 0.5, "the shake should be visible without stabilizer, got \(off) px/frame")
            #expect(on < off * 0.75, "stabilized \(on) px/frame vs unstabilized \(off)")
        }
    }

    // (i) Instant replay saves a playable clip.
    @Test func replayBufferSavesAPlayableClip() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            let buffer = ReplayBuffer(seconds: 10)
            rig.fake.joinLate(consumer: buffer, on: rig.session)
            defer { rig.session.removeConsumer(buffer) }
            let ok = await waitUntil(15) { buffer.bufferedSeconds >= 2.5 }
            #expect(ok, "buffered \(buffer.bufferedSeconds) s")
            let saved: URL? = await withCheckedContinuation { c in buffer.save { c.resume(returning: $0) } }
            let url = try #require(saved, "save failed: \(buffer.lastError ?? "?")")
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == rig.dir.standardizedFileURL.path)
            let info = try await inspect(url)
            #expect(info.playable)
            #expect(info.tracks == 1)
            #expect(info.size == CGSize(width: 1920, height: 1080))
            #expect(info.duration > 1.5, "duration \(info.duration)")
            let img = try await frame(of: url, at: 0)
            let s = stats(img)
            #expect(s.lumaStdDev > 5, "first frame looks uniform (std \(s.lumaStdDev))")
            let isGrey = abs(s.r - s.g) < 3 && abs(s.g - s.b) < 3 && abs(s.r - 128) < 10
            #expect(!isGrey, "first frame is the grey of a decoder without a reference")
        }
    }

    // (j) Loss, silence and recovery on the app side.
    @Test(.tags(.slow), .enabled(if: !skipSlow)) func decoderRecoversWhenAFreshIDRArrives() async throws {
        try await withRig { rig in
            let session = rig.session
            try await startAndWaitForPicture(rig)
            await sleep(1)
            #expect(session.isWaitingForKeyframe == false)
            #expect(session.hasRecentPicture(within: 1))
            let before = session.latestDecodedFrame()

            // The helper goes quiet for 4 s; the drop is reported like NAL backpressure reports it.
            rig.fake.dropFrames(1, notifyingSessions: true)
            rig.fake.setSilent(true)
            await sleep(4)
            #expect(session.hasRecentPicture(within: 1) == false, "no input, so no fresh picture")
            #expect(session.isWaitingForKeyframe, "dropped input must put the decoder back to waiting for a keyframe")

            // Traffic resumes with P frames only: they are useless without a reference and must not be shown.
            rig.fake.setSilent(false)
            let resumedAt = Date()
            await sleep(1.5)
            #expect(session.isWaitingForKeyframe, "P frames alone must not restart the decoder")
            #expect(session.hasRecentPicture(within: 1) == false)

            // The recovery policy, driven with the decoder's real state, asks for a keyframe and then a reconnect.
            var policy = KeyframeRecoveryPolicy()
            let t0 = Date()
            #expect(policy.update(waiting: session.isWaitingForKeyframe, now: t0) == .requestKeyframe)
            #expect(policy.update(waiting: session.isWaitingForKeyframe, now: t0.addingTimeInterval(0.5)) == .none)
            #expect(policy.update(waiting: session.isWaitingForKeyframe, now: t0.addingTimeInterval(1.6)) == .requestKeyframe)
            #expect(policy.update(waiting: session.isWaitingForKeyframe, now: t0.addingTimeInterval(3.1)) == .reconnect)

            // The goggles answer with a fresh SPS+IDR.
            rig.fake.requestKeyframe()
            let recovered = await waitUntil(8) { !session.isWaitingForKeyframe && session.hasRecentPicture(within: 0.5) }
            #expect(recovered, "picture did not resume after a fresh IDR")
            #expect(rig.fake.idrDelivered == 2)
            let after = session.latestDecodedFrame()
            #expect(after != nil && after !== before)
            // Once recovered, the policy stands down.
            #expect(policy.update(waiting: session.isWaitingForKeyframe, now: t0.addingTimeInterval(4)) == .none)
            _ = resumedAt
            // The decoder keeps decoding the P frames that follow the new IDR.
            await sleep(1)
            #expect(session.hasRecentPicture(within: 0.5))
            #expect(session.teardownCount == 0)
        }
    }

    // (k) The clip sidecar and the gallery index.
    @Test func recordingWritesMetadataSidecarAndGalleryFindsIt() async throws {
        try await withRig { rig in
            try await startAndWaitForPicture(rig)
            await sleep(0.5)
            let dims = rig.session.dimensions
            let (rec, url) = try rig.makeRecorder(name: "meta") {
                ClipRecordInfo(gogglesName: "Test Goggles 3", gogglesSerial: "FAKE0001",
                               width: dims.map { Int($0.width) }, height: dims.map { Int($0.height) }, fps: 60)
            }
            await sleep(3)
            _ = await rig.finish(rec)
            let sidecar = ClipMetadataStore.sidecarURL(for: url)
            let wrote = await waitUntil(5) { FileManager.default.fileExists(atPath: sidecar.path) }
            #expect(wrote, "no .gvmeta.json next to the clip")
            #expect(sidecar.lastPathComponent.hasSuffix(".gvmeta.json"))
            let meta = try #require(ClipMetadataStore.read(for: url))
            #expect(meta.gogglesName == "Test Goggles 3")
            #expect(meta.gogglesSerial == "FAKE0001")
            #expect(meta.width == 1920 && meta.height == 1080)

            ClipMetadataStore.update(for: url) { $0.tags = ["Coast", "fpv"] }
            // Another, untagged clip from different goggles.
            let other = rig.dir.appendingPathComponent("other.mov")
            try FileManager.default.copyItem(at: url, to: other)
            ClipMetadataStore.update(for: other) { $0.gogglesName = "Other Goggles"; $0.tags = ["city"] }

            var clips = ClipLibrary.scan(rig.dir)
            #expect(clips.count == 2)
            for i in clips.indices { clips[i].metadata = ClipMetadataStore.read(for: clips[i].url) }

            var byName = ClipFilter(); byName.text = "test goggles"
            #expect(ClipIndex.apply(byName, to: clips).map(\.name) == ["meta.mov"])
            var byTag = ClipFilter(); byTag.tags = ["coast"]
            #expect(ClipIndex.apply(byTag, to: clips).map(\.name) == ["meta.mov"])
            var byGoggles = ClipFilter(); byGoggles.goggles = ClipGoggles.key(meta)
            #expect(ClipIndex.apply(byGoggles, to: clips).map(\.name) == ["meta.mov"])
            #expect(ClipIndex.knownGoggles(clips).count == 2)
        }
    }

    private func decodedFrameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }

    // MARK: Motion measurement

    /// Mean frame-to-frame translation (pixels at 480 px width) of the recorded picture.
    private func meanMotion(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        let ci = CIContext()
        func small(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
            var dst: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 480, 270, kCVPixelFormatType_32BGRA, nil, &dst) == kCVReturnSuccess, let dst else { return nil }
            let scale = 480.0 / Double(CVPixelBufferGetWidth(pb))
            ci.render(CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: dst)
            return dst
        }
        var prev: CVPixelBuffer?
        var total = 0.0, n = 0, index = 0
        while let sample = out.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index >= 15, let pb = CMSampleBufferGetImageBuffer(sample), let s = small(pb) else { continue }
            if let p = prev, let m = Stabilizer.measure(from: p, to: s) {
                total += (m.x * m.x + m.y * m.y).squareRoot(); n += 1
            }
            prev = s
        }
        try #require(n > 20, "only \(n) frame pairs measured")
        return total / Double(n)
    }
}
