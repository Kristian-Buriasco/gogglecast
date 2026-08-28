import Foundation

// ─────────────────────────────────────────────────────────────────────────
// Task 3.3, design.md plan text: "Annex-B -> AVCC conversion" for slice
// NALs. Deliberately much simpler than `ParameterSetSplitter.split(_:)`
// (Task 3.2): a slice NAL arrives from `HelperClient` as ONE already
// -delimited unit per callback -- confirmed against
// `GogglesPipeline/Pipeline.swift` (`delegate?.pipeline(didEmitNAL: nal,
// ...)`, one call per completed `FrameReassembler` frame) and
// `GogglesXPC/Protocols.swift`'s `nalUnit` doc comment ("One H.264 NAL
// unit") -- so there is no multi-NAL blob to scan and split here, just one
// leading start code to strip and replace.
// ─────────────────────────────────────────────────────────────────────────

enum AnnexBConversionError: Error, Equatable {
    /// `data` didn't begin with a recognized Annex-B start code (neither
    /// the 3-byte `00 00 01` nor 4-byte `00 00 00 01` form). Per
    /// `Pipeline.swift`'s "00 00 00 01 start code FrameReassembler always
    /// prepends" comment this shouldn't happen for real slice NALs off the
    /// wire, but a malformed/corrupt NAL (design.md §7's "Corrupt/
    /// undecodable NAL" row) is exactly the case this guards against rather
    /// than assumes away.
    case noStartCode
    /// A start code was found but nothing followed it.
    case emptyPayload
}

enum NALAnnexBToAVCC {
    /// Converts one Annex-B start-code-prefixed NAL into AVCC form: the
    /// leading start code stripped and replaced with a 4-byte big-endian
    /// length prefix (matching the `nalUnitHeaderLength: 4` used to build
    /// the format description in `ParameterSetSplitter.makeFormatDescription`
    /// -- VideoToolbox needs the two to agree).
    ///
    /// Handles both 3-byte (`00 00 01`) and 4-byte (`00 00 00 01`) start
    /// codes for the same reason `ParameterSetSplitter.split(_:)` does
    /// (design.md §5.3 point 1's "don't assume either form"), even though
    /// the one confirmed real-world producer (`FrameReassembler`) always
    /// uses the 4-byte form.
    static func convert(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard let startCodeLength = startCodeLength(in: bytes) else {
            throw AnnexBConversionError.noStartCode
        }
        let payload = bytes[startCodeLength...]
        guard !payload.isEmpty else {
            throw AnnexBConversionError.emptyPayload
        }

        var result = Data(capacity: 4 + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(contentsOf: payload)
        return result
    }

    private static func startCodeLength(in bytes: [UInt8]) -> Int? {
        if bytes.count >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x00, bytes[3] == 0x01 {
            return 4
        }
        if bytes.count >= 3, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01 {
            return 3
        }
        return nil
    }
}
