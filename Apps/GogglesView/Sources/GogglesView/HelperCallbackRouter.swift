import Foundation
import GogglesXPC

/// One device's callback set on a shared `HelperClient`. Every closure is
/// delivered on the main queue, same as the legacy `HelperClient.on*` closures.
public struct HelperDeviceHandlers {
    public var onDeviceChanged: ((DeviceInfo?) -> Void)?
    public var onHelperStateChanged: ((Int, String?) -> Void)?
    public var onNALUnit: ((Data, UInt8, Bool, UInt64) -> Void)?
    public var onStats: ((StreamStats) -> Void)?
    public var onBatteryChanged: ((Int?) -> Void)?

    public init(
        onDeviceChanged: ((DeviceInfo?) -> Void)? = nil,
        onHelperStateChanged: ((Int, String?) -> Void)? = nil,
        onNALUnit: ((Data, UInt8, Bool, UInt64) -> Void)? = nil,
        onStats: ((StreamStats) -> Void)? = nil,
        onBatteryChanged: ((Int?) -> Void)? = nil
    ) {
        self.onDeviceChanged = onDeviceChanged
        self.onHelperStateChanged = onHelperStateChanged
        self.onNALUnit = onNALUnit
        self.onStats = onStats
        self.onBatteryChanged = onBatteryChanged
    }
}

/// Opaque handle returned by `HelperClient.addConnectionStateObserver`.
public struct HelperConnectionObserverToken: Hashable {
    fileprivate let id: UUID
}

/// Multi-subscriber routing table behind `HelperClient`: per-deviceId handler
/// sets (one per open goggles window) plus any number of connection-state
/// observers (the picker and every coordinator). Lock-protected because XPC
/// callbacks look handlers up off the main thread (including the per-NAL path).
final class HelperCallbackRouter {
    private let lock = NSLock()
    private var deviceHandlers: [String: HelperDeviceHandlers] = [:]
    private var connectionObservers: [UUID: (HelperClientConnectionState) -> Void] = [:]
    /// Insertion order, so observers fire deterministically.
    private var observerOrder: [UUID] = []

    func setHandlers(_ handlers: HelperDeviceHandlers, for deviceId: String) {
        lock.lock(); deviceHandlers[deviceId] = handlers; lock.unlock()
    }

    func removeHandlers(for deviceId: String) {
        lock.lock(); deviceHandlers[deviceId] = nil; lock.unlock()
    }

    func handlers(for deviceId: String) -> HelperDeviceHandlers? {
        lock.lock(); defer { lock.unlock() }
        return deviceHandlers[deviceId]
    }

    var registeredDeviceIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(deviceHandlers.keys)
    }

    func addConnectionObserver(_ observer: @escaping (HelperClientConnectionState) -> Void) -> HelperConnectionObserverToken {
        let id = UUID()
        lock.lock()
        connectionObservers[id] = observer
        observerOrder.append(id)
        lock.unlock()
        return HelperConnectionObserverToken(id: id)
    }

    func removeConnectionObserver(_ token: HelperConnectionObserverToken) {
        lock.lock()
        connectionObservers[token.id] = nil
        observerOrder.removeAll { $0 == token.id }
        lock.unlock()
    }

    func connectionObserverSnapshot() -> [(HelperClientConnectionState) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return observerOrder.compactMap { connectionObservers[$0] }
    }
}
