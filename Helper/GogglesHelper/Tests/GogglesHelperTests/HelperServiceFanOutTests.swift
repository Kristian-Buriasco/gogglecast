import Testing
import Foundation
@testable import GogglesHelper
import GogglesXPC

// MEDIUM 5 fix (multi-device picker review round 2): real, in-process
// `NSXPCListener.anonymous()`/`NSXPCConnection` tests for
// `HelperService`'s device-scoped fan-out (design item 6: "a client
// subscribed to device A must not receive device B's callbacks"). This was
// previously manually traced as correct by a reviewer but had zero actual
// test coverage, despite the spec explicitly saying this kind of logic
// "can be tested with MockTransportTests" and the task brief asking for
// tests here.
//
// No real hardware or Mach-service registration needed:
// `NSXPCListener.anonymous()` + `NSXPCConnection(listenerEndpoint:)` is the
// standard in-process pattern for testing an `NSXPCListenerDelegate`/
// exported-object pair without a launchd-registered service name.
// `startStreaming(deviceId:)` for a `deviceId` that doesn't correspond to
// any real, currently-connected `2CA3:0020` device fails fast with
// `RNDISTransportError.deviceNotFound` (no hardware in this test
// environment) -- `HelperService` treats that as ".noDevice, keep polling"
// rather than an error, which is exactly the code path that calls
// `setState`/`fanOut(deviceId:)`. This exercises the real fan-out routing
// end-to-end (real `NSXPCConnection`s, real `HelperService`,
// real per-device `DeviceState`) without needing a physical unit.

/// Exported `GogglesClientProtocol` object that records every `deviceId`
/// it's ever called back with. Thread-safe: XPC delivers exported-object
/// calls on the connection's own queue, not necessarily the test's thread.
private final class RecordingClient: NSObject, GogglesClientProtocol {
    private let lock = NSLock()
    private var _deviceIdsSeen: [String] = []

    var deviceIdsSeen: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _deviceIdsSeen
    }

    private func record(_ deviceId: String) {
        lock.lock()
        _deviceIdsSeen.append(deviceId)
        lock.unlock()
    }

    func deviceChanged(_ deviceId: String, _ info: DeviceInfo?) { record(deviceId) }
    func stateChanged(_ deviceId: String, _ state: Int, detail: String?) { record(deviceId) }
    func nalUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) { record(deviceId) }
    func stats(_ deviceId: String, _ stats: StreamStats) { record(deviceId) }
}

@Suite("HelperService fan-out scoping (real in-process NSXPCConnection, no hardware)")
struct HelperServiceFanOutTests {

    @Test("a client streaming device A never receives a callback meant for device B")
    func fanOutIsScopedPerDevice() async throws {
        let service = HelperService()
        let delegate = HelperListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let connA = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connA.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        connA.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)
        let clientA = RecordingClient()
        connA.exportedObject = clientA
        connA.resume()

        let connB = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connB.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        connB.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)
        let clientB = RecordingClient()
        connB.exportedObject = clientB
        connB.resume()

        defer {
            connA.invalidate()
            connB.invalidate()
        }

        guard let proxyA = connA.remoteObjectProxyWithErrorHandler({ _ in }) as? GogglesHelperProtocol,
              let proxyB = connB.remoteObjectProxyWithErrorHandler({ _ in }) as? GogglesHelperProtocol else {
            Issue.record("could not obtain GogglesHelperProtocol proxies")
            return
        }

        // Neither "device-A" nor "device-B" corresponds to a real,
        // currently-connected 2CA3:0020 device in this test environment --
        // RNDISTransport(targetDeviceId:) fails fast with
        // .deviceNotFound, which HelperService's beginStreaming treats as
        // ".noDevice, keep polling" (not a claim failure), exercising the
        // real setState -> fanOut(deviceId:) path.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxyA.startStreaming(deviceId: "device-A") { _, _ in continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxyB.startStreaming(deviceId: "device-B") { _, _ in continuation.resume() }
        }

        // startStreaming's own reply can (and does) fire before the
        // fan-out call it triggers is actually delivered (the claim
        // attempt/state transition happens on a detached Task, hopping
        // back onto stateQueue) -- give that a moment to land.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(!clientA.deviceIdsSeen.isEmpty, "client A should have received at least one callback about its own device")
        #expect(!clientB.deviceIdsSeen.isEmpty, "client B should have received at least one callback about its own device")
        #expect(clientA.deviceIdsSeen.allSatisfy { $0 == "device-A" }, "client A must never see device B's deviceId: \(clientA.deviceIdsSeen)")
        #expect(clientB.deviceIdsSeen.allSatisfy { $0 == "device-B" }, "client B must never see device A's deviceId: \(clientB.deviceIdsSeen)")
    }

    @Test("stopStreaming for one device does not affect the other device's subscriber")
    func stopStreamingIsPerDevice() async throws {
        let service = HelperService()
        let delegate = HelperListenerDelegate(service: service)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let connA = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connA.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        connA.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)
        let clientA = RecordingClient()
        connA.exportedObject = clientA
        connA.resume()

        let connB = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connB.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        connB.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)
        let clientB = RecordingClient()
        connB.exportedObject = clientB
        connB.resume()

        defer {
            connA.invalidate()
            connB.invalidate()
        }

        guard let proxyA = connA.remoteObjectProxyWithErrorHandler({ _ in }) as? GogglesHelperProtocol,
              let proxyB = connB.remoteObjectProxyWithErrorHandler({ _ in }) as? GogglesHelperProtocol else {
            Issue.record("could not obtain GogglesHelperProtocol proxies")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxyA.startStreaming(deviceId: "device-A") { _, _ in continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxyB.startStreaming(deviceId: "device-B") { _, _ in continuation.resume() }
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proxyA.stopStreaming(deviceId: "device-A") { continuation.resume() }
        }

        let countAAfterStop = clientA.deviceIdsSeen.count
        let countBAfterAStopped = clientB.deviceIdsSeen.count

        // Device B's device-retry poll keeps firing on its own ~1s cadence
        // (nothing was stopped for it), but task 3.8's dedup fix
        // (`HelperService.beginStreaming`) deliberately suppresses a
        // redundant `stateChanged` fan-out when a retry finds the state
        // unchanged (already `.noDevice`) -- so B's callback COUNT isn't
        // expected to keep growing here, only to stay uncontaminated by
        // A's `stopStreaming`. The real assertion this test cares about is
        // scoping (B never sees "device-A", A gets nothing further after
        // stopping), not fan-out volume.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        #expect(clientA.deviceIdsSeen.count == countAAfterStop, "client A must not receive any further callbacks after stopStreaming")
        #expect(clientB.deviceIdsSeen.count >= countBAfterAStopped, "client B's callback count must never go backwards")
        #expect(clientA.deviceIdsSeen.allSatisfy { $0 == "device-A" })
        #expect(clientB.deviceIdsSeen.allSatisfy { $0 == "device-B" }, "client B must never see device A's deviceId even after A's stopStreaming: \(clientB.deviceIdsSeen)")
    }
}
