import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import IOKit.audio

// The "DJI Goggles 3" virtual camera: one device, one 1920x1080 BGRA source stream. While a client has
// the stream open, `HelperFeed` pulls the goggles' H.264 from the helper, and decoded pictures are
// pushed to the stream. With no recent picture a "no signal" card is sent instead, so consumers never
// see a hung or silently black camera.

private let deviceID = UUID(uuidString: "8C6E1E9E-6B0A-4B7B-9C3B-5B9E7B9E0A01")!
private let streamID = UUID(uuidString: "8C6E1E9E-6B0A-4B7B-9C3B-5B9E7B9E0A02")!

private let nominalFrameDuration = CMTime(value: 1, timescale: 30)
/// A live picture older than this is replaced by the no-signal card.
private let staleFrameNs: UInt64 = 1_000_000_000

final class StreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let feed = HelperFeed()
    private let renderer = FrameRenderer()
    private let format: CMIOExtensionStreamFormat
    private let queue = DispatchQueue(label: "com.kburiasco.gogglesview.camera.stream")

    // All below on `queue`.
    private var timer: DispatchSourceTimer?
    private var streaming = false
    private var statusMessage = "Starting…"
    private var latestFrame: CVPixelBuffer?
    private var latestFrameNs: UInt64 = 0
    private var lastSentNs: UInt64 = 0
    private var discontinuity = true

    init(localizedName: String) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(FrameRenderer.width), height: Int32(FrameRenderer.height),
            extensions: nil, formatDescriptionOut: &description)
        format = CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: nominalFrameDuration,
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil)
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .source,
            clockType: .hostTime, source: self)

        let queue = self.queue
        feed.onFrame = { [weak self] frame in
            queue.async { self?.receive(frame) }
        }
        feed.onStatus = { [weak self] status in
            queue.async { self?.statusMessage = status ?? "" }
        }
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = nominalFrameDuration }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // One fixed format; the 30 fps pacing is nominal, consumers resample.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        Logging.camera.info("startStream")
        queue.async { [self] in
            self.streaming = true
            self.discontinuity = true
            self.latestFrame = nil
            self.latestFrameNs = 0
            self.statusMessage = "Starting…"
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
            timer.setEventHandler { [self] in tick() }
            timer.resume()
            self.timer = timer
        }
        feed.start()
    }

    func stopStream() throws {
        Logging.camera.info("stopStream")
        feed.stop()
        queue.async {
            self.streaming = false
            self.timer?.cancel()
            self.timer = nil
            self.latestFrame = nil
        }
    }

    // MARK: - Frame path (on `queue`)

    private func receive(_ frame: CVPixelBuffer) {
        guard streaming else { return }
        latestFrame = frame
        latestFrameNs = DispatchTime.now().uptimeNanoseconds
        statusMessage = ""
        // Send the new picture right away rather than waiting for the next tick.
        send(frame, live: true)
    }

    private func tick() {
        guard streaming else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if latestFrame != nil, now &- latestFrameNs > staleFrameNs {
            latestFrame = nil
            statusMessage = "Signal lost"
        }
        // Live frames are pushed from `receive`; the tick only covers the no-signal card.
        guard latestFrame == nil else { return }
        let message = statusMessage.isEmpty ? "No signal" : statusMessage
        guard let card = renderer.noSignal(message: message) else { return }
        send(card, live: false)
    }

    private func send(_ pixelBuffer: CVPixelBuffer, live: Bool) {
        let output = live ? renderer.render(pixelBuffer) : pixelBuffer
        guard let output else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Keep timestamps strictly increasing even when a tick and a live frame land together.
        let stamp = max(now, lastSentNs + 1)
        guard let sample = renderer.sampleBuffer(for: output, hostTimeNs: stamp, frameDuration: nominalFrameDuration) else { return }
        lastSentNs = stamp
        stream.send(sample, discontinuity: discontinuity ? .unknown : [], hostTimeInNanoseconds: stamp)
        discontinuity = false
    }
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: StreamSource!

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)
        streamSource = StreamSource(localizedName: "\(localizedName) Video")
        do {
            try device.addStream(streamSource.stream)
        } catch {
            Logging.camera.fault("failed to add stream to device: \(String(describing: error), privacy: .public)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "DJI Goggles 3" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "DJI Goggles 3")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            Logging.camera.fault("failed to add device to provider: \(String(describing: error), privacy: .public)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "GogglesView" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
