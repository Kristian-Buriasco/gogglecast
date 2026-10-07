import Foundation
import CoreVideo
import GogglesXPC

/// Pulls the goggles' H.264 stream from the helper's Mach service and decodes it. The helper is the
/// only process that owns the USB device (design §4.1); this is one more fan-out subscriber, like the app.
///
/// All state lives on `queue`. `start()`/`stop()` are called from the CMIO stream's start/stop.
final class HelperFeed: NSObject {
    /// Decoded picture (VideoToolbox thread).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// A short human-readable reason there is no picture, or nil once frames flow. Called on `queue`.
    var onStatus: ((String?) -> Void)?

    fileprivate let queue = DispatchQueue(label: "com.kburiasco.gogglesview.camera.helperfeed")
    private let decoder = FrameDecoder()
    private var connection: NSXPCConnection?
    private var running = false
    private var deviceId: String?
    private var retryDelay: TimeInterval = 1
    private var generation = 0

    override init() {
        super.init()
        decoder.onFrame = { [weak self] frame in self?.onFrame?(frame) }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.retryDelay = 1
            self.connect()
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.generation += 1
            if let deviceId = self.deviceId, let proxy = self.proxy() {
                proxy.stopStreaming(deviceId: deviceId) {}
            }
            self.teardownConnection()
            self.decoder.reset()
        }
    }

    // MARK: - Connection

    private func connect() {
        generation += 1
        let gen = generation
        publish("Starting…")

        let conn = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)
        conn.exportedObject = ExportedClient(owner: self, generation: gen)
        conn.invalidationHandler = { [weak self] in self?.queue.async { self?.connectionLost(gen) } }
        conn.interruptionHandler = { [weak self] in self?.queue.async { self?.connectionLost(gen) } }
        connection = conn
        conn.resume()

        guard let proxy = proxy() else { return scheduleRetry(gen) }
        proxy.protocolVersion { [weak self] version in
            self?.queue.async {
                guard let self, gen == self.generation, self.running else { return }
                guard version == currentProtocolVersion else {
                    Logging.helper.error("helper protocol \(version, privacy: .public) != \(currentProtocolVersion, privacy: .public)")
                    self.publish("Update GogglesView")
                    return
                }
                self.pickDeviceAndStream(gen)
            }
        }
    }

    private func pickDeviceAndStream(_ gen: Int) {
        guard let proxy = proxy() else { return scheduleRetry(gen) }
        proxy.enumerateDevices { [weak self] devices in
            self?.queue.async {
                guard let self, gen == self.generation, self.running else { return }
                guard let device = devices.first else {
                    self.publish("Connect the goggles by USB")
                    return self.scheduleRetry(gen)
                }
                self.deviceId = device.deviceId
                self.proxy()?.startStreaming(deviceId: device.deviceId) { [weak self] ok, error in
                    self?.queue.async {
                        guard let self, gen == self.generation, self.running else { return }
                        if ok {
                            self.retryDelay = 1
                            self.publish("Waiting for video…")
                        } else {
                            Logging.helper.error("startStreaming failed: \(String(describing: error), privacy: .public)")
                            self.publish("Goggles unavailable")
                            self.scheduleRetry(gen)
                        }
                    }
                }
            }
        }
    }

    private func connectionLost(_ gen: Int) {
        guard gen == generation, running else { return }
        Logging.helper.info("helper connection lost")
        decoder.reset()
        publish("GogglesView helper is not running")
        scheduleRetry(gen)
    }

    private func scheduleRetry(_ gen: Int) {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.running else { return }
            self.teardownConnection()
            self.connect()
        }
    }

    private func teardownConnection() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    private func proxy() -> GogglesHelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            Logging.helper.error("XPC error: \(String(describing: error), privacy: .public)")
        } as? GogglesHelperProtocol
    }

    private func publish(_ status: String?) { onStatus?(status) }

    // MARK: - Callbacks (called on `queue`)

    fileprivate func receivedNAL(_ data: Data, isParameterSet: Bool, generation gen: Int) {
        guard gen == generation, running else { return }
        decoder.handle(nalData: data, isParameterSet: isParameterSet)
    }

    fileprivate func receivedState(_ state: Int, generation gen: Int) {
        guard gen == generation, running, let state = GogglesState(rawValue: state) else { return }
        switch state {
        case .live: publish(nil)
        case .noDevice: publish("Connect the goggles by USB")
        case .claiming, .resolving, .handshaking: publish("Connecting to goggles…")
        case .claimFailed: publish("Could not open the goggles")
        case .waitingForKeyframe: publish("Waiting for video…")
        case .stalled: publish("Signal lost")
        case .noHelper: publish("GogglesView helper is not installed")
        }
    }
}

/// `GogglesClientProtocol` object exported on the connection. Hops every callback onto the feed's queue.
private final class ExportedClient: NSObject, GogglesClientProtocol {
    private weak var owner: HelperFeed?
    private let generation: Int

    init(owner: HelperFeed, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    func nalUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        guard let owner else { return }
        let generation = generation
        owner.queue.async { [weak owner] in owner?.receivedNAL(data, isParameterSet: isParameterSet, generation: generation) }
    }

    func stateChanged(_ deviceId: String, _ state: Int, detail: String?) {
        guard let owner else { return }
        let generation = generation
        owner.queue.async { [weak owner] in owner?.receivedState(state, generation: generation) }
    }

    func deviceChanged(_ deviceId: String, _ info: DeviceInfo?) {}
    func stats(_ deviceId: String, _ stats: StreamStats) {}
    func batteryChanged(_ deviceId: String, percent: Int) {}
}
