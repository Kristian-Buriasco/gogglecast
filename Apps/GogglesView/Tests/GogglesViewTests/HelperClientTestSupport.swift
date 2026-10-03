import Foundation
@testable import GogglesView
import GogglesXPC

/// Drives a never-connected `HelperClient` through its REAL routing entry
/// points (the same `handle*` methods the exported XPC object calls), with
/// main-queue delivery made synchronous so tests can assert immediately.
extension HelperClient {
    private func synchronous() { deliverOnMain = { $0() } }

    func sendConnectionState(_ state: HelperClientConnectionState) {
        synchronous(); broadcastConnectionState(state)
    }

    func sendHelperState(_ deviceId: String, _ raw: Int, _ detail: String?) {
        synchronous(); handleStateChanged(deviceId, raw, detail: detail)
    }

    func sendNAL(_ deviceId: String, _ data: Data, _ nalType: UInt8, _ isParameterSet: Bool, _ hostTime: UInt64) {
        synchronous(); handleNALUnit(deviceId, data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }

    func sendStats(_ deviceId: String, _ stats: StreamStats) {
        synchronous(); handleStats(deviceId, stats)
    }

    func sendDeviceInfo(_ deviceId: String, _ info: DeviceInfo?) {
        synchronous(); handleDeviceChanged(deviceId, info)
    }

    func sendBattery(_ deviceId: String, _ percent: Int) {
        synchronous(); handleBatteryChanged(deviceId, percent: percent)
    }
}
