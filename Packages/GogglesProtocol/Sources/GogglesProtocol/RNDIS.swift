import Foundation

/// Pure message-building/parsing logic for the RNDIS control and data
/// protocol used to talk to the goggles' composite USB device (MS-RNDIS).
///
/// This type deliberately contains NO USB transport code -- no libusb, no
/// IOKit, nothing beyond Foundation. It only knows how to build and parse
/// the raw bytes of RNDIS messages; the actual control/bulk transfers over
/// USB are `GogglesUSB`'s job (a later task). This is a byte-exact Swift
/// port of the Python prototype's `rndis.py` message-building functions.
public enum RNDIS {

    // MARK: - Message type constants

    public static let REMOTE_NDIS_INITIALIZE_MSG: UInt32 = 0x0000_0002
    public static let REMOTE_NDIS_INITIALIZE_CMPLT: UInt32 = 0x8000_0002
    public static let REMOTE_NDIS_SET_MSG: UInt32 = 0x0000_0005
    public static let REMOTE_NDIS_SET_CMPLT: UInt32 = 0x8000_0005
    public static let REMOTE_NDIS_QUERY_MSG: UInt32 = 0x0000_0004
    public static let REMOTE_NDIS_QUERY_CMPLT: UInt32 = 0x8000_0004
    public static let REMOTE_NDIS_PACKET_MSG: UInt32 = 0x0000_0001

    // MARK: - OIDs / packet filter bits

    public static let OID_GEN_CURRENT_PACKET_FILTER: UInt32 = 0x0001_010E
    public static let OID_802_3_CURRENT_ADDRESS: UInt32 = 0x0101_0102
    public static let NDIS_PACKET_TYPE_DIRECTED: UInt32 = 0x0001
    public static let NDIS_PACKET_TYPE_BROADCAST: UInt32 = 0x0004
    public static let NDIS_PACKET_TYPE_ALL_MULTICAST: UInt32 = 0x0010
    public static let NDIS_PACKET_TYPE_PROMISCUOUS: UInt32 = 0x0020

    // MARK: - Control-message builders (pure byte layout, no USB I/O)

    /// Builds the 24-byte REMOTE_NDIS_INITIALIZE_MSG body (all fields
    /// little-endian): {type, length=24, requestId, majorVersion=1,
    /// minorVersion=0, maxTransferSize=0x4000}.
    /// Matches Python `rndis.rndis_initialize`'s message-building step
    /// (this function does NOT perform the USB round trip -- that's
    /// `GogglesUSB`'s responsibility).
    public static func initializeMsg(requestId: UInt32 = 1) -> Data {
        var msg = Data()
        msg.appendLE(REMOTE_NDIS_INITIALIZE_MSG)
        msg.appendLE(UInt32(24))
        msg.appendLE(requestId)
        msg.appendLE(UInt32(1))       // majorVersion
        msg.appendLE(UInt32(0))       // minorVersion
        msg.appendLE(UInt32(0x4000))  // maxTransferSize
        return msg
    }

    /// Builds a REMOTE_NDIS_SET_MSG for the given OID and value: header is
    /// {type, msgLen=28+infoLen, requestId, oid, infoLen, infoBufferOffset=20,
    /// deviceVcHandle=0}, all little-endian, followed by the raw value bytes.
    /// Matches Python `rndis.rndis_set`'s message-building step.
    public static func setMsg(oid: UInt32, value: Data, requestId: UInt32 = 2) -> Data {
        let infoLen = UInt32(value.count)
        let headerLen: UInt32 = 28
        let msgLen = headerLen + infoLen
        var msg = Data()
        msg.appendLE(REMOTE_NDIS_SET_MSG)
        msg.appendLE(msgLen)
        msg.appendLE(requestId)
        msg.appendLE(oid)
        msg.appendLE(infoLen)
        msg.appendLE(UInt32(20))  // infoBufferOffset
        msg.appendLE(UInt32(0))   // deviceVcHandle
        msg.append(value)
        return msg
    }

    /// Builds a 28-byte REMOTE_NDIS_QUERY_MSG for the given OID: {type,
    /// msgLen=28, requestId, oid, infoLen=0, infoBufferOffset=20,
    /// deviceVcHandle=0}, all little-endian, no trailing value.
    /// Matches Python `rndis.rndis_query`'s message-building step.
    public static func queryMsg(oid: UInt32, requestId: UInt32 = 3) -> Data {
        var msg = Data()
        msg.appendLE(REMOTE_NDIS_QUERY_MSG)
        msg.appendLE(UInt32(28))
        msg.appendLE(requestId)
        msg.appendLE(oid)
        msg.appendLE(UInt32(0))   // infoLen
        msg.appendLE(UInt32(20))  // infoBufferOffset
        msg.appendLE(UInt32(0))   // deviceVcHandle
        return msg
    }

    // MARK: - Data-path framing (REMOTE_NDIS_PACKET_MSG)

    /// Wraps a raw Ethernet frame in a 44-byte REMOTE_NDIS_PACKET_MSG
    /// header: {type, msgLen, dataOffset=36, dataLen, then 7 zero u32
    /// fields}, all little-endian, followed by the raw frame. DataOffset
    /// is counted from the DataOffset field itself (44 - 8 = 36).
    /// Matches Python `rndis.wrap_packet_msg`.
    public static func wrapPacketMsg(_ frame: Data) -> Data {
        let headerLen = 44
        let dataOffset = UInt32(headerLen - 8)
        let totalLen = UInt32(headerLen + frame.count)
        var msg = Data()
        msg.appendLE(REMOTE_NDIS_PACKET_MSG)
        msg.appendLE(totalLen)
        msg.appendLE(dataOffset)
        msg.appendLE(UInt32(frame.count))
        for _ in 0..<7 {
            msg.appendLE(UInt32(0))
        }
        msg.append(frame)
        return msg
    }

    /// Extracts raw Ethernet frames from a bulk-IN read buffer that may
    /// contain one or more RNDIS_PACKET_MSG structures back to back.
    /// Iterates by msgLen until msgType != PACKET_MSG, msgLen == 0, or
    /// fewer than 44 bytes remain. Matches Python `rndis.unwrap_packet_msg`.
    public static func unwrapPacketMsg(_ buf: Data) -> [Data] {
        let bytes = [UInt8](buf)
        var frames: [Data] = []
        var off = 0
        while off + 44 <= bytes.count {
            let msgType = readLEU32(bytes, off)
            let msgLen = readLEU32(bytes, off + 4)
            guard msgType == REMOTE_NDIS_PACKET_MSG, msgLen != 0 else { break }
            let dataOff = readLEU32(bytes, off + 8)
            let dataLen = readLEU32(bytes, off + 12)
            let frameStart = off + 8 + Int(dataOff)
            let frameEnd = frameStart + Int(dataLen)
            if frameStart >= 0, frameEnd <= bytes.count, frameStart <= frameEnd {
                let frame = Data(bytes[frameStart..<frameEnd])
                if !frame.isEmpty {
                    frames.append(frame)
                }
            }
            off += Int(msgLen)
        }
        return frames
    }

    private static func readLEU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
