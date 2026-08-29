import Foundation
import CoreMediaIO
import IOKit.audio

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: the minimum viable `CMIOExtensionProviderSource` /
// `CMIOExtensionDeviceSource` / `CMIOExtensionStreamSource` skeleton needed
// for `systemextensionsctl` to accept this bundle as a camera extension and
// register one do-nothing device. No frame production, no real formats
// selection logic, no properties beyond what each protocol marks
// `@required`. This is explicitly NOT the real Task 4.2 camera device --
// see this target's `Package.swift` doc comment.
// ─────────────────────────────────────────────────────────────────────────

private let deviceID = UUID(uuidString: "8C6E1E9E-6B0A-4B7B-9C3B-5B9E7B9E0A01")!
private let streamID = UUID(uuidString: "8C6E1E9E-6B0A-4B7B-9C3B-5B9E7B9E0A02")!

final class StreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let deviceSource: DeviceSource

    init(localizedName: String, deviceSource: DeviceSource) {
        self.deviceSource = deviceSource
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        // One dummy 1920x1080/30 BGRA format -- enough for the provider to
        // report *something* to satisfy `CMIOExtensionStreamSource`'s
        // `@required formats`. This spike never actually sends a sample
        // buffer.
        guard let formatDescription = try? CMFormatDescription(
            mediaType: .video,
            mediaSubType: .init(rawValue: kCVPixelFormatType_32BGRA)
        ) else {
            return []
        }
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 30),
            minFrameDuration: CMTime(value: 1, timescale: 30),
            validFrameDurations: nil
        )
        return [format]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // No-op: nothing here is settable in a do-nothing spike.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        Logging.spike.info("SPIKE: CMIOExtensionStream startStream() called by a CMIO client -- do-nothing spike device has no frames to send")
    }

    func stopStream() throws {
        Logging.spike.info("SPIKE: CMIOExtensionStream stopStream() called")
    }
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: StreamSource!

    init(localizedName: String) {
        super.init()
        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )
        self.streamSource = StreamSource(localizedName: "\(localizedName) Stream", deviceSource: self)
        do {
            try device.addStream(streamSource.stream)
        } catch {
            Logging.spike.fault("SPIKE: failed to add stream to device: \(String(describing: error), privacy: .public)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "GogglesCamera Spike"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No-op.
    }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!
    let helperConnector = HelperSpikeConnector()

    init(clientQueue: DispatchQueue?) {
        super.init()
        self.provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        self.deviceSource = DeviceSource(localizedName: "GogglesCamera (spike)")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            Logging.spike.fault("SPIKE: failed to add device to provider: \(String(describing: error), privacy: .public)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        Logging.spike.info("SPIKE: CMIO client connected to provider")
    }

    func disconnect(from client: CMIOExtensionClient) {
        Logging.spike.info("SPIKE: CMIO client disconnected from provider")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "GogglesView (spike)"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No-op.
    }
}
