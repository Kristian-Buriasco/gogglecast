import Foundation
import GogglesUSB

/// Polls the goggles' battery over IF4 DUML on its own utility queue, never
/// touching the video pipeline. If IF4 can't be claimed it logs once and
/// stops; video is unaffected. `onReading` gets 0...100, or -1 for unknown,
/// and only when the value changes.
final class BatteryPoller {
    static let interval: TimeInterval = 5
    /// Consecutive failed queries before reporting -1 (avoids OSD flicker
    /// on a single dropped reply).
    static let failuresBeforeUnknown = 3

    private let queue: DispatchQueue
    private weak var transport: RNDISTransport?
    private let deviceId: String
    private let onReading: (Int) -> Void

    private var timer: DispatchSourceTimer?
    private var channel: DUMLControlChannel?
    private var openAttempted = false
    private var lastReported = -1
    private var failures = 0

    init(transport: RNDISTransport, deviceId: String, onReading: @escaping (Int) -> Void) {
        self.transport = transport
        self.deviceId = deviceId
        self.onReading = onReading
        self.queue = DispatchQueue(label: "\(Logging.subsystem).battery", qos: .utility)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // First poll shortly after claim so the overlay fills in quickly.
        timer.schedule(deadline: .now() + 1.0, repeating: Self.interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let transport else { stop(); return }
        if channel == nil {
            guard !openAttempted else { return }
            openAttempted = true
            guard let opened = transport.openDUMLControlChannel() else {
                Logging.usb.error("[\(self.deviceId, privacy: .public)] IF4 claim failed; battery polling disabled for this session")
                stop()
                return
            }
            channel = opened
            Logging.usb.info("[\(self.deviceId, privacy: .public)] claimed IF4 for DUML battery polling")
        }
        guard let channel else { return }
        if let percent = channel.queryBatteryPercent() {
            failures = 0
            report(percent)
        } else {
            failures += 1
            if failures >= Self.failuresBeforeUnknown { report(-1) }
        }
    }

    private func report(_ percent: Int) {
        guard percent != lastReported else { return }
        lastReported = percent
        Logging.pipeline.info("[\(self.deviceId, privacy: .public)] goggles battery: \(percent)%")
        onReading(percent)
    }
}
