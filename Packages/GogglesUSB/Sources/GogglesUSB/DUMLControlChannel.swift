import Foundation
import GogglesProtocol

/// DUML request/reply over the goggles' vendor interface IF4 (bulk OUT 0x04,
/// bulk IN 0x85), on the same device handle `RNDISTransport` holds for video.
/// See docs/telemetry-research.md "Probe round 2".
///
/// The I/O is injected (`write`/`read` closures) so the request/reply matching
/// logic is testable without hardware; `RNDISTransport.openDUMLControlChannel()`
/// wires it to real libusb bulk transfers. Not thread-safe: call from one
/// queue at a time.
public final class DUMLControlChannel {

    public static let interfaceNumber: Int32 = 4
    public static let epBulkOut: UInt8 = 0x04
    public static let epBulkIn: UInt8 = 0x85

    static let senderApp: UInt8 = 0x2A
    static let batteryModule: UInt8 = 0x59
    static let cmdTypeRequest: UInt8 = 0x40
    static let cmdSetSmartBattery: UInt8 = 0x0D
    static let cmdIdGetDynamicInfo: UInt8 = 0x02
    static let batteryPercentOffset = 21

    /// Returns false on write failure.
    public typealias Write = (_ frame: Data) -> Bool
    /// Returns whatever bytes arrived within `timeoutMs` (empty on timeout),
    /// or nil on a hard error.
    public typealias Read = (_ timeoutMs: UInt32) -> Data?

    private let write: Write
    private let read: Read
    private var seq: UInt16
    private var pending = Data()

    public init(write: @escaping Write, read: @escaping Read, initialSeq: UInt16 = UInt16.random(in: 0x3000...0xEFFF)) {
        self.write = write
        self.read = read
        self.seq = initialSeq
    }

    /// Pure reply parser: nil unless the payload is long enough and the
    /// status byte (index 0) is 0. Values above 100 are rejected as garbage.
    public static func batteryPercent(fromReplyPayload payload: Data) -> Int? {
        let bytes = [UInt8](payload)
        guard bytes.count > batteryPercentOffset, bytes[0] == 0 else { return nil }
        let value = Int(bytes[batteryPercentOffset])
        return value <= 100 ? value : nil
    }

    /// Whether `packet` is the reply to the battery request sent with `seq`.
    static func isBatteryReply(_ packet: DUML.DumlPacket, seq: UInt16) -> Bool {
        packet.cmdSet == cmdSetSmartBattery && packet.cmdId == cmdIdGetDynamicInfo
            && packet.sender == batteryModule && packet.seq == seq && (packet.cmdType & 0x80) != 0
    }

    /// One blocking request/reply round trip, bounded by `timeout`. Unrelated
    /// traffic (the ~1 Hz `00:82` heartbeat, stale replies) is discarded.
    public func queryBatteryPercent(timeout: TimeInterval = 0.6) -> Int? {
        seq &+= 1
        let mySeq = seq
        let frame = DUML.build(
            sender: Self.senderApp, receiver: Self.batteryModule, seq: mySeq,
            cmdType: Self.cmdTypeRequest, cmdSet: Self.cmdSetSmartBattery, cmdId: Self.cmdIdGetDynamicInfo
        )
        guard write(frame) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remainingMs = UInt32(max(1, min(150, deadline.timeIntervalSinceNow * 1000)))
            guard let chunk = read(remainingMs) else { return nil }
            if chunk.isEmpty { continue }
            pending.append(chunk)
            let (packets, tail) = DUML.parseStream(pending, onMalformedFrame: { _, _ in })
            pending = tail
            if pending.count > 4096 { pending.removeAll() }
            if let reply = packets.first(where: { Self.isBatteryReply($0, seq: mySeq) }) {
                return Self.batteryPercent(fromReplyPayload: reply.payload)
            }
        }
        return nil
    }

    /// Developer aid (reverse engineering): registers as an app with the goggles, as DJI Fly does, then reads the
    /// channel for `duration` seconds, answers the requests that ask for an answer, and hands every other packet to
    /// `onPacket` (the once-a-second heartbeats are filtered out). Only used while the sniff marker file exists.
    public func sniff(duration: TimeInterval, register: Bool, onPacket: (DUML.DumlPacket) -> Void) {
        if register {
            for payload in [Data([0x17, 0x00, 0x00, 0x23, 0x00, 0x41, 0x50, 0x50, 0, 0, 0, 0, 0, 0x02]),
                            Data([0x1D, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x07, 0x00]) + Data("1.21.1".utf8)] {
                seq &+= 1
                _ = write(DUML.build(sender: Self.senderApp, receiver: 0x3C, seq: seq, cmdType: Self.cmdTypeRequest,
                                     cmdSet: 0x00, cmdId: 0x88, payload: payload))
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard let chunk = read(UInt32(max(1, min(150, deadline.timeIntervalSinceNow * 1000)))) else { return }
            if chunk.isEmpty { continue }
            pending.append(chunk)
            let (packets, tail) = DUML.parseStream(pending, onMalformedFrame: { _, _ in })
            pending = tail
            if pending.count > 4096 { pending.removeAll() }
            for packet in packets {
                let isRequest = packet.cmdType & 0x80 == 0
                let wantsReply = (packet.cmdType >> 5) & 0x03 != 0
                if isRequest && wantsReply {
                    var reply = Data([0x00])
                    if packet.cmdSet == 0x00 && packet.cmdId == 0x81 {
                        reply = (Data([0x00]) + Data("APP".utf8) + Data(repeating: 0, count: 29) + Data([0x00, 0x02])
                                 + Data(repeating: 0, count: 6) + Data([0x05, 0x1C]) + Data(repeating: 0, count: 6))
                        reply = reply.prefix(64) + Data(repeating: 0, count: max(0, 64 - reply.count))
                    } else if packet.cmdSet == 0x00 && packet.cmdId == 0x88 && packet.payload.first == 0x19 {
                        reply = Data([0x1A, 0x00, 0x00, 0x00, 0x00])
                    }
                    _ = write(DUML.build(sender: packet.receiver, receiver: packet.sender, seq: packet.seq,
                                         cmdType: 0x80 | (packet.cmdType & 0x1F), cmdSet: packet.cmdSet, cmdId: packet.cmdId, payload: reply))
                }
                let isHeartbeat = (packet.cmdSet == 0x00 && (packet.cmdId == 0x81 || packet.cmdId == 0x82 || packet.cmdId == 0x88))
                if !isHeartbeat { onPacket(packet) }
            }
        }
    }

    /// Developer aid (reverse engineering): sends one request frame from the app address.
    @discardableResult
    public func sendDeveloperRequest(receiver: UInt8, cmdSet: UInt8, cmdId: UInt8, payload: Data) -> Bool {
        seq &+= 1
        return write(DUML.build(sender: Self.senderApp, receiver: receiver, seq: seq, cmdType: Self.cmdTypeRequest,
                                cmdSet: cmdSet, cmdId: cmdId, payload: payload))
    }

    /// Restarts the goggles' share session, which makes them send a fresh keyframe (the same thing as switching
    /// "Share Liveview" off and on in the goggles' menu). Found by reverse engineering: the Wi-Fi module (DUML address
    /// 0x1B) accepts `07:42 stop_ground_wifi` and `07:41 start_ground_wifi` from an app and acknowledges both with
    /// status 0; the video stops and comes back, with a keyframe, about two seconds after the start. The goggles
    /// ignore these unless an app has registered first, so this registers (once) and keeps answering the goggles'
    /// requests while it waits.
    public func restartShare(register: Bool) {
        sniff(duration: 0.1, register: register) { _ in }
        seq &+= 1
        _ = write(DUML.build(sender: Self.senderApp, receiver: 0x1B, seq: seq, cmdType: Self.cmdTypeRequest, cmdSet: 0x07, cmdId: 0x42))
        sniff(duration: 1.2, register: false) { _ in }
        seq &+= 1
        _ = write(DUML.build(sender: Self.senderApp, receiver: 0x1B, seq: seq, cmdType: Self.cmdTypeRequest, cmdSet: 0x07, cmdId: 0x41))
        sniff(duration: 0.8, register: false) { _ in }
    }
}
