import Foundation
import GogglesUSB
import GogglesProtocol

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
    private var sniffRegistered = false
    private var lastShareRestart: Date?
    /// Gives the pipeline's own session id (developer hook below).
    var sessionIdProvider: (() -> UInt16)?
    var mbQueue: ((Data) -> Void)?
    private var type5Counter: UInt8 = 0
    private var type5Seq: UInt16 = 0xE9D0

    /// Restarts the goggles' share session so they send a keyframe (see `DUMLControlChannel.restartShare`).
    /// Runs on this poller's queue, which owns the IF4 channel; at most once every 20 s. Returns false when it
    /// declined (too soon, or IF4 is not available).
    @discardableResult
    func restartShare() -> Bool {
        if let last = lastShareRestart, Date().timeIntervalSince(last) < 20 { return false }
        lastShareRestart = Date()
        queue.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            Logging.pipeline.info("[\(self.deviceId, privacy: .public)] restarting the goggles' share session to get a keyframe")
            channel.restartShare(register: !self.sniffRegistered)
            self.sniffRegistered = true
        }
        return true
    }

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
        // Developer aid: `touch /tmp/gogglesview-duml-sniff` makes the helper log every control message the goggles send.
        if FileManager.default.fileExists(atPath: "/tmp/gogglesview-duml-sniff") {
            // `echo "1B 07 42" > /tmp/gogglesview-duml-send` (receiver cmdSet cmdId [payload hex], all hex) sends one
            // request per line from the helper, which owns the USB interface; the reply shows in the sniff log.
            if let text = try? String(contentsOfFile: "/tmp/gogglesview-duml-send", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/gogglesview-duml-send")
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: " ").map(String.init)
                    guard f.count >= 3, let r = UInt8(f[0], radix: 16), let cs = UInt8(f[1], radix: 16), let ci = UInt8(f[2], radix: 16) else { continue }
                    var payload = Data()
                    if f.count > 3 { var hex = Substring(f[3]); while hex.count >= 2 { if let b = UInt8(hex.prefix(2), radix: 16) { payload.append(b) }; hex = hex.dropFirst(2) } }
                    let ok = channel.sendDeveloperRequest(receiver: r, cmdSet: cs, cmdId: ci, payload: payload)
                    Logging.pipeline.info("[sniff] SENT \(String(format: "2A>%02X %02X:%02X", r, cs, ci), privacy: .public) payload=\(payload.map { String(format: "%02x", $0) }.joined(), privacy: .public) ok=\(ok)")
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            // `echo "ack 02 3C 00 88 1700..." > /tmp/gogglesview-udp-duml` (mode sender receiver cmdSet cmdId [payload], hex)
            // sends one DUML request from the app over the UDP link: `ack` appends it to the next video acknowledgement,
            // `t5` sends it as a type-0x05 packet (the documented app-to-goggles channels).
            if let text = try? String(contentsOfFile: "/tmp/gogglesview-udp-duml", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/gogglesview-udp-duml")
                let session = sessionIdProvider?() ?? 0
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: " ").map(String.init)
                    guard f.count >= 5, let snd = UInt8(f[1], radix: 16), let rcv = UInt8(f[2], radix: 16),
                          let cs = UInt8(f[3], radix: 16), let ci = UInt8(f[4], radix: 16) else { continue }
                    var payload = Data()
                    if f.count > 5 { var hex = Substring(f[5]); while hex.count >= 2 { if let byte = UInt8(hex.prefix(2), radix: 16) { payload.append(byte) }; hex = hex.dropFirst(2) } }
                    let frame = DUML.build(sender: snd, receiver: rcv, seq: UInt16.random(in: 0x100...0xF000), cmdType: 0x40, cmdSet: cs, cmdId: ci, payload: payload)
                    if f[0] == "ack" { mbQueue?(frame) }
                    else if f[0] == "t5" {
                        try? transport.send(WireProtocol.buildType5(dumlFrame: frame, seq: type5Seq, counter: type5Counter, sessionId: session))
                        type5Seq &+= 1; type5Counter &+= 1
                    }
                    Logging.pipeline.info("[sniff] UDP \(f[0], privacy: .public) \(String(format: "%02X>%02X %02X:%02X", snd, rcv, cs, ci), privacy: .public) payload=\(payload.map { String(format: "%02x", $0) }.joined(), privacy: .public) session \(session)")
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            // `echo "02" > /tmp/gogglesview-udp-iframe` sweeps DUML 02:B3 (request keyframe) over the UDP link from that
            // sender address to every receiver address, inside the pipeline's own session (reverse engineering).
            if let text = try? String(contentsOfFile: "/tmp/gogglesview-udp-iframe", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: "/tmp/gogglesview-udp-iframe")
                let session = sessionIdProvider?() ?? 0
                for line in text.split(separator: "\n") {
                    guard let sender = UInt8(line.trimmingCharacters(in: .whitespaces), radix: 16) else { continue }
                    Logging.pipeline.info("[sniff] UDP 02:B3 sweep from \(String(format: "%02X", sender), privacy: .public) session \(session) starting")
                    for receiver in 0...255 {
                        let frame = DUML.build(sender: sender, receiver: UInt8(receiver), seq: 0x9100 &+ UInt16(receiver),
                                               cmdType: 0x40, cmdSet: 0x02, cmdId: 0xB3, payload: Data())
                        try? transport.send(WireProtocol.buildTelemetryWithDUML(dumlFrame: frame, seq: UInt16.random(in: 1...0xFFFF), sessionId: session))
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    Logging.pipeline.info("[sniff] UDP 02:B3 sweep from \(String(format: "%02X", sender), privacy: .public) done")
                }
            }
            channel.sniff(duration: 4.0, register: !sniffRegistered) { p in
                Logging.pipeline.info("[sniff] \(String(format: "%02X>%02X %02X:%02X type=%02X len=%d", p.sender, p.receiver, p.cmdSet, p.cmdId, p.cmdType, p.payload.count), privacy: .public) \(p.payload.prefix(40).map { String(format: "%02x", $0) }.joined(), privacy: .public)")
            }
            sniffRegistered = true
        }
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
