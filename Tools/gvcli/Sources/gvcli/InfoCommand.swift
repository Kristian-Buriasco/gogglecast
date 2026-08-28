import Foundation
import GogglesUSB

/// `gvcli info`: connects over USB/RNDIS, extracts and prints `DeviceInfo`
/// (product/serial/bcdDevice/bus/address, same fields `RNDISTransport`
/// captures at connect time), then exits -- no video pipeline is brought
/// up. `transport` falling out of scope at the end of this function
/// triggers `RNDISTransport.deinit`, releasing IF0/IF1 cleanly, same as
/// every other exit path in this tool.
func runInfoCommand() async throws {
    FileHandle.standardError.write(Data("[gvcli] Connecting to goggles over USB (RNDIS)...\n".utf8))
    let transport = try RNDISTransport()
    printDeviceInfoBanner(transport.deviceInfo)
    let macHex = transport.gogglesMac.map { String(format: "%02x", $0) }.joined(separator: ":")
    print("Goggles RNDIS MAC (ARP-resolved): \(macHex)")
    if let diag = transport.arpSweepDiagnostic {
        FileHandle.standardError.write(Data(
            "[gvcli] Note: ARP resolution required the multi-subnet sweep fallback (subnet \(diag.subnet), ip \(diag.ip)).\n".utf8
        ))
    }
}
