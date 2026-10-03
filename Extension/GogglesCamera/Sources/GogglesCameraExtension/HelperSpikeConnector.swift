import Foundation
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: THE spike. Everything else in this target (`main.swift`'s
// CMIOExtensionProvider/Device/Stream skeleton) exists only to make the
// bundle installable at all -- this file is the one question the whole
// task is answering: can this sandboxed CMIOExtension process reach the
// helper's Team-ID-prefixed Mach service and receive a real `stats`
// callback?
//
// Deliberately NOT `HelperClient.swift` copied wholesale: no reconnect
// backoff, no `HelperClientConnectionState` machine, no fps counter, no
// public closure surface. `HelperClient`'s `.privileged` reasoning (see
// its own doc comment) still applies verbatim -- the helper is an
// `SMAppService.daemon`-installed `/Library/LaunchDaemons` job, so
// `.privileged` is used here too -- but this connector's whole job is
// "connect once, export a client, log the first stats callback, log
// clearly if that never happens." Nothing here is meant to survive into
// Task 4.2 unchanged.
// ─────────────────────────────────────────────────────────────────────────
final class HelperSpikeConnector: NSObject {
    private var connection: NSXPCConnection?
    private var exportedClient: ExportedSpikeClient?
    private var receivedFirstStats = false

    func connect() {
        Logging.spike.info("SPIKE: attempting NSXPCConnection(machServiceName: \(helperMachServiceName, privacy: .public), options: .privileged) from inside the sandboxed extension")

        let newConnection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)

        let exported = ExportedSpikeClient()
        exported.owner = self
        newConnection.exportedObject = exported
        self.exportedClient = exported

        newConnection.invalidationHandler = { [weak self] in
            Logging.spike.fault("SPIKE RESULT: connection INVALIDATED before any stats callback was received. This is the strongest evidence the Mach lookup did not succeed (bootstrap_look_up denied by the sandbox, or the exported-object handshake was rejected). received_stats=\(self?.receivedFirstStats ?? false, privacy: .public)")
        }
        newConnection.interruptionHandler = {
            Logging.spike.error("SPIKE: connection interrupted (helper process restarted, most likely) -- not treated as final failure by itself")
        }

        self.connection = newConnection
        newConnection.resume()
        Logging.spike.info("SPIKE: NSXPCConnection resumed, calling protocolVersion(reply:) as the first round trip...")

        guard let proxy = newConnection.remoteObjectProxyWithErrorHandler({ error in
            Logging.spike.fault("SPIKE RESULT: remoteObjectProxy error -- \(String(describing: error), privacy: .public). This is direct evidence the Mach lookup/XPC round trip failed from inside the sandbox.")
        }) as? GogglesHelperProtocol else {
            Logging.spike.fault("SPIKE RESULT: could not obtain GogglesHelperProtocol proxy at all")
            return
        }

        proxy.protocolVersion { reported in
            Logging.spike.info("SPIKE RESULT: protocolVersion round trip SUCCEEDED, helper reports \(reported, privacy: .public), app expects \(GogglesXPC.currentProtocolVersion, privacy: .public) -- the Mach lookup and XPC handshake both work from inside the sandbox.")
            // startStreaming isn't required to answer the mach-lookup
            // question (protocolVersion already proves the round trip
            // works), but the brief specifically asks for one logged
            // `stats` callback as the deliverable, and `stats` only flows
            // while streaming. This spike doesn't enumerate devices (that
            // would be real Task 4.2-scope work, out of bounds for a
            // throwaway Mach-lookup spike) -- an empty deviceId is a
            // deliberate placeholder that fails the same way "no device"
            // already failed pre-multi-device, since this spike can't run
            // at all yet regardless (blocked on a paid Apple Developer
            // Program membership, see docs/dev-setup.md).
            proxy.startStreaming(deviceId: "") { ok, error in
                if let error {
                    Logging.spike.error("SPIKE: startStreaming failed (expected if no goggles are connected to this machine right now): \(String(describing: error), privacy: .public)")
                } else {
                    Logging.spike.info("SPIKE: startStreaming ok=\(ok, privacy: .public) -- awaiting a stats callback (requires live goggles hardware; absence of one does not by itself mean the Mach lookup failed, see protocolVersion result above)")
                }
            }
        }
    }

    fileprivate func handleStats(_ stats: StreamStats) {
        receivedFirstStats = true
        Logging.spike.fault("SPIKE RESULT: received a real `stats` callback from the helper over the sandboxed extension's Mach connection -- fps=\(stats.fps, privacy: .public) bitrate=\(stats.bitrateKbps, format: .fixed(precision: 1), privacy: .public)kbps drops=\(stats.drops, privacy: .public). THE MACH LOOKUP WORKS.")
    }

    fileprivate func handleDeviceChanged(_ info: DeviceInfo?) {
        Logging.spike.info("SPIKE: deviceChanged callback received (proves the exported GogglesClientProtocol object is reachable, independent of stats): \(info?.product ?? "nil", privacy: .public)")
    }

    fileprivate func handleStateChanged(_ state: Int, detail: String?) {
        Logging.spike.info("SPIKE: stateChanged callback received: state=\(state, privacy: .public) detail=\(detail ?? "nil", privacy: .public)")
    }
}

/// Exported `GogglesClientProtocol` object, same weak-back-reference shape
/// as `HelperClient.swift`'s `ExportedClient` and for the identical reason
/// (the connection retains this strongly; a strong reference back to
/// `HelperSpikeConnector` would be a retain cycle).
private final class ExportedSpikeClient: NSObject, GogglesClientProtocol {
    weak var owner: HelperSpikeConnector?

    // `deviceId` params below are accepted-but-ignored: this spike doesn't
    // enumerate/target a specific device (see the empty-deviceId comment
    // at the `startStreaming` call site), so there's only ever one
    // (degenerate) device stream to correlate callbacks against.

    func deviceChanged(_ deviceId: String, _ info: DeviceInfo?) {
        owner?.handleDeviceChanged(info)
    }

    func stateChanged(_ deviceId: String, _ state: Int, detail: String?) {
        owner?.handleStateChanged(state, detail: detail)
    }

    func nalUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        // Not logged per-NAL (would flood the log at ~30fps) -- the spike
        // only cares about `stats`, which arrives at a much lower rate.
    }

    func stats(_ deviceId: String, _ stats: StreamStats) {
        owner?.handleStats(stats)
    }

    func batteryChanged(_ deviceId: String, percent: Int) {}
}
