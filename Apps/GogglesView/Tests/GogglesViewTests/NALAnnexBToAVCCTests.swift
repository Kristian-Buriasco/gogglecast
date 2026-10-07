import Testing
import Foundation
@testable import GogglesView
import GogglesH264

@Suite("NALAnnexBToAVCC")
struct NALAnnexBToAVCCTests {

    @Test("4-byte start code is stripped and replaced with a 4-byte big-endian length prefix")
    func fourByteStartCode() throws {
        let payload: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x10]
        let annexB = Data([0x00, 0x00, 0x00, 0x01] + payload)

        let avcc = try NALAnnexBToAVCC.convert(annexB)

        #expect(avcc.count == 4 + payload.count)
        let length = avcc.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(length == UInt32(payload.count))
        #expect(Array(avcc.suffix(payload.count)) == payload)
    }

    @Test("3-byte start code is also handled, not just 4-byte")
    func threeByteStartCode() throws {
        let payload: [UInt8] = [0x41, 0x9a, 0x24]
        let annexB = Data([0x00, 0x00, 0x01] + payload)

        let avcc = try NALAnnexBToAVCC.convert(annexB)

        #expect(avcc.count == 4 + payload.count)
        #expect(Array(avcc.suffix(payload.count)) == payload)
    }

    @Test("no start code throws .noStartCode")
    func noStartCode() {
        let bytes = Data([0x65, 0x88, 0x84])
        #expect(throws: AnnexBConversionError.noStartCode) {
            _ = try NALAnnexBToAVCC.convert(bytes)
        }
    }

    @Test("start code with nothing after it throws .emptyPayload")
    func emptyPayload() {
        let bytes = Data([0x00, 0x00, 0x00, 0x01])
        #expect(throws: AnnexBConversionError.emptyPayload) {
            _ = try NALAnnexBToAVCC.convert(bytes)
        }
    }
}
