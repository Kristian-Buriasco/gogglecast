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
}
