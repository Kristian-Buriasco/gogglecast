import Foundation
import GogglesProtocol
import GogglesPipeline
import GogglesUSB
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 2.2: the server-side implementation of `GogglesHelperProtocol`
// (design §5.5, `GogglesXPC`, task 2.1) -- the subscriber registry, the
// fan-out rule, and the 5s teardown linger all live here.
//
// One `HelperService` instance is `exportedObject` on every accepted
// `NSXPCConnection` (see `HelperListenerDelegate`); `NSXPCConnection`
// dispatches each exported-object method call on its own connection's
// queue, potentially concurrently across different connections, so every
// piece of mutable state this type owns is only ever touched from
// `stateQueue` (a private serial `DispatchQueue`) -- including from
// `PipelineDelegate`'s callbacks, which arrive from whatever thread the
// running pipeline `Task` happens to be on.
//
// Fan-out rule (design §5.5, copied verbatim in the task brief):
//   "the helper starts the hardware on the first subscriber that calls
//   startStreaming and tears it down when the last one disconnects, with a
//   5 s linger to survive an app relaunch. Subscribers are independent;
//   one crashing does not stop the others."
//
// This implementation distinguishes two subscriber sets:
//   - `connections`: every currently-connected client (added when its
//     connection is accepted, removed on invalidation). ALL of these
//     receive every `nalUnit`/`stateChanged`/`deviceChanged`/`stats`
//     fan-out call -- "every connected subscriber gets every ... callback"
//     per the task brief, not just the ones that called `startStreaming`.
//   - `streamingSubscriberIDs`: the subset that has called `startStreaming`
//     and not yet called `stopStreaming` (or disconnected). Hardware
//     bring-up/teardown is driven purely by this set's size, matching the
//     "first subscriber .. last one disconnects" rule.
//
// One subscriber's connection dying doesn't affect delivery to the others
// because fan-out uses each connection's own
// `remoteObjectProxyWithErrorHandler` -- a broken/dead connection just logs
// and is skipped, no custom liveness tracking is layered on top (task
// brief's explicit instruction).
// ─────────────────────────────────────────────────────────────────────────

final class HelperService: NSObject, GogglesHelperProtocol, PipelineDelegate {

    private let stateQueue = DispatchQueue(label: "\(Logging.subsystem).state")

    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var streamingSubscriberIDs: Set<ObjectIdentifier> = []

    private var pipelineTask: Task<Void, Never>?
    private var lingerTimer: DispatchSourceTimer?

    /// The concrete transport `beginStreaming` constructed, kept alongside
    /// (not instead of) `GogglesPipeline.currentTransport`. See
    /// `RNDISTransport.close()`'s doc comment: the running pipeline
    /// `Task` holds its own strong reference to this same instance for its
    /// entire lifetime, so nil-ing the *global* `currentTransport` alone
    /// never actually stops that `Task` while this daemon process keeps
    /// running (unlike `gvcli`'s SIGINT/`--stdout` SIGTERM paths, which
    /// exit the process outright). `teardownHardware()` calls `.close()`
    /// on this directly to break that deadlock.
    private var activeTransport: RNDISTransport?
    /// Bumped every `beginStreaming` call; lets a superseded bring-up's own
    /// completion handler (below) recognize it's stale -- relevant for
    /// `reconnect()`, which calls `teardownHardware()` (whose `.close()` is
    /// synchronous/blocking but whose *effect* on the old pipeline `Task`
    /// is only observed asynchronously) immediately followed by a new
    /// `beginStreaming()`. Without this, the old `Task`'s completion could
    /// fire after the new one has already been assigned and clear the
    /// *new* `pipelineTask`/`activeTransport` out from under it.
    private var pipelineGeneration = 0

    private var currentDeviceInfoValue: GogglesXPC.DeviceInfo?
    private var currentStateValue: GogglesState = .noDevice
    private var everReachedLive = false

    // MARK: - Connection bookkeeping (called by HelperListenerDelegate)

    /// Registers a freshly-accepted connection as a fan-out subscriber and
    /// immediately brings it up to speed with whatever device/state info
    /// is already known, so it doesn't have to wait for the next event to
    /// know where things stand.
    func registerConnection(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.connections[id] = connection
            Logging.xpc.info("subscriber connected (\(self.connections.count) total)")
            if let proxy = self.remoteClient(for: connection) {
                proxy.deviceChanged(self.currentDeviceInfoValue)
                proxy.stateChanged(self.currentStateValue.rawValue, detail: nil)
            }
        }
    }

    /// Removes a connection from both the general and streaming subscriber
    /// sets on invalidation (crash, force-quit, explicit `invalidate()`),
    /// starting the 5s teardown linger if it was the last streaming
    /// subscriber.
    func unregisterConnection(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.connections.removeValue(forKey: id)
            let wasStreaming = self.streamingSubscriberIDs.remove(id) != nil
            Logging.xpc.info("subscriber disconnected (\(self.connections.count) remaining, wasStreaming=\(wasStreaming))")
            if wasStreaming {
                self.scheduleTeardownIfNoSubscribers()
            }
        }
    }

    private func remoteClient(for connection: NSXPCConnection) -> GogglesClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            Logging.xpc.error("remoteObjectProxy error, dropping this subscriber's callback: \(String(describing: error))")
        } as? GogglesClientProtocol
    }

    /// Must only be called while already executing on `stateQueue`.
    private func fanOut(_ body: (GogglesClientProtocol) -> Void) {
        for connection in connections.values {
            if let proxy = remoteClient(for: connection) {
                body(proxy)
            }
        }
    }

    /// Must only be called while already executing on `stateQueue`.
    private func setState(_ state: GogglesState, detail: String? = nil) {
        currentStateValue = state
        if state == .live { everReachedLive = true }
        Logging.pipeline.info("state -> \(String(describing: state)) (\(state.rawValue))\(detail.map { " [\($0)]" } ?? "")")
        fanOut { $0.stateChanged(state.rawValue, detail: detail) }
    }

    // MARK: - GogglesHelperProtocol

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(currentProtocolVersion)
    }

    func currentDeviceInfo(reply: @escaping (GogglesXPC.DeviceInfo?) -> Void) {
        stateQueue.async { reply(self.currentDeviceInfoValue) }
    }

    func startStreaming(reply: @escaping (Bool, NSError?) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(false, HelperError.noConnectionContext.asNSError())
            return
        }
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.lingerTimer?.cancel()
            self.lingerTimer = nil
            let wasEmpty = self.streamingSubscriberIDs.isEmpty
            self.streamingSubscriberIDs.insert(id)
            Logging.xpc.info("startStreaming from subscriber (now \(self.streamingSubscriberIDs.count) streaming)")
            if wasEmpty, self.pipelineTask == nil {
                self.beginStreaming(reply: reply)
            } else {
                // Hardware already up (or in the middle of coming up) for
                // an earlier subscriber -- this one just joins the fan-out
                // it's already registered for via registerConnection.
                reply(true, nil)
            }
        }
    }

    func stopStreaming(reply: @escaping () -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply()
            return
        }
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.streamingSubscriberIDs.remove(id)
            Logging.xpc.info("stopStreaming from subscriber (\(self.streamingSubscriberIDs.count) streaming remain)")
            self.scheduleTeardownIfNoSubscribers()
            reply()
        }
    }

    func requestIFrame(reply: @escaping () -> Void) {
        stateQueue.async {
            // Best-effort (design §8.1): the goggles' DUML 02:B3 handling
            // is unreliable even on its own regular 1.5s retry cadence
            // (which `runPipeline` already drives internally); this is
            // just an extra nudge on top, sent with a fresh session id
            // since the pipeline's own in-flight session id isn't exposed
            // outside its running Task. No failure is ever reported --
            // matches the protocol's documented contract.
            if let transport = currentTransport {
                let seq = WireProtocol.randomSessionId()
                let sessionId = WireProtocol.randomSessionId()
                try? transport.send(WireProtocol.requestIFrameTelemetry(seq: seq, sessionId: sessionId))
                Logging.pipeline.info("requestIFrame: sent best-effort DUML 02:B3 nudge")
            } else {
                Logging.pipeline.info("requestIFrame: no active transport, ignoring")
            }
            reply()
        }
    }

    func reconnect(reply: @escaping () -> Void) {
        stateQueue.async {
            Logging.usb.info("reconnect requested: full teardown + design §5.1 rerun")
            self.lingerTimer?.cancel()
            self.lingerTimer = nil
            self.teardownHardware()
            if self.streamingSubscriberIDs.isEmpty {
                self.setState(.noDevice)
                reply()
            } else {
                self.beginStreaming(reply: { _, _ in })
                reply()
            }
        }
    }

    // MARK: - Hardware lifecycle (must only run on stateQueue)

    /// Brings the hardware up: claims IF0/IF1 + RNDIS init + ARP resolve
    /// (all inside `RNDISTransport.init`, design §5.1), then starts the
    /// shared pipeline (`GogglesPipeline.runPipeline`) with `self` as its
    /// delegate. `RNDISTransport()` is a blocking call (USB control
    /// transfers, up to a few seconds of ARP resolution), so it runs on a
    /// detached Task rather than blocking `stateQueue` (which would freeze
    /// every other subscriber's method calls and all fan-out for that
    /// entire window).
    private func beginStreaming(reply: @escaping (Bool, NSError?) -> Void) {
        setState(.claiming)
        pipelineGeneration += 1
        let myGeneration = pipelineGeneration
        Logging.usb.info("claiming IF0/IF1 and bringing up RNDIS...")
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let transport = try RNDISTransport()
                let raw = transport.deviceInfo
                let info = GogglesXPC.DeviceInfo(
                    product: raw.product,
                    serial: raw.serial,
                    idVendor: raw.idVendor,
                    idProduct: raw.idProduct,
                    bcdDevice: raw.bcdDevice,
                    bus: raw.bus,
                    address: raw.address
                )
                Logging.usb.info("claimed IF0/IF1, device: \(raw.product ?? "?", privacy: .public)")
                self.stateQueue.async {
                    guard self.pipelineGeneration == myGeneration else { return }
                    self.activeTransport = transport
                    self.currentDeviceInfoValue = info
                    self.fanOut { $0.deviceChanged(info) }
                    self.setState(.handshaking)
                    reply(true, nil)
                }
                let task = Task {
                    do {
                        try await runPipeline(transport: transport, sink: nil, stats: false, delegate: self)
                        Logging.pipeline.info("runPipeline returned (transport released, e.g. unplug or teardown)")
                    } catch {
                        Logging.pipeline.error("runPipeline ended with error: \(String(describing: error))")
                    }
                    self.stateQueue.async {
                        // Stale (superseded by a later beginStreaming, e.g.
                        // reconnect()) -- don't clobber the newer bring-up's
                        // state.
                        guard self.pipelineGeneration == myGeneration else { return }
                        self.pipelineTask = nil
                        if currentTransport == nil {
                            self.activeTransport = nil
                            self.currentDeviceInfoValue = nil
                            self.setState(.noDevice)
                        }
                    }
                }
                self.stateQueue.async {
                    guard self.pipelineGeneration == myGeneration else { return }
                    self.pipelineTask = task
                }
            } catch {
                let nsError = error as NSError
                Logging.usb.error("claim/RNDIS bring-up failed: \(String(describing: error))")
                self.stateQueue.async {
                    guard self.pipelineGeneration == myGeneration else { return }
                    self.setState(.claimFailed, detail: nsError.localizedDescription)
                    self.pipelineTask = nil
                    reply(false, nsError)
                }
            }
        }
    }

    /// Starts the 5s linger (design §5.5) once the streaming-subscriber set
    /// goes empty, unless one is already pending. If a new `startStreaming`
    /// arrives before it fires, `startStreaming` cancels it directly. If it
    /// fires with the set still empty, the hardware is released.
    private func scheduleTeardownIfNoSubscribers() {
        guard streamingSubscriberIDs.isEmpty, pipelineTask != nil || currentTransport != nil, lingerTimer == nil else {
            return
        }
        Logging.xpc.info("no streaming subscribers left; starting 5s teardown linger")
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lingerTimer = nil
            guard self.streamingSubscriberIDs.isEmpty else {
                Logging.xpc.info("linger expired but a subscriber reconnected; keeping hardware up")
                return
            }
            Logging.usb.info("linger expired with no subscribers; releasing USB interfaces")
            self.teardownHardware()
            self.setState(.noDevice)
        }
        timer.resume()
        lingerTimer = timer
    }

    /// Releases the USB interfaces while this daemon process keeps running.
    ///
    /// Unlike `installSigtermHandler` (which just nils the global
    /// `currentTransport` and immediately `exit(0)`s -- process death
    /// reclaims the device regardless of whether `deinit` finishes first),
    /// this path must actually stop the specific running pipeline `Task`
    /// without killing the process. Nil-ing the global alone doesn't do
    /// that: `runPipeline`'s own `transport` parameter holds a strong
    /// reference for that `Task`'s entire lifetime, so the global going nil
    /// never triggers `RNDISTransport.deinit`, and the pipeline `Task`
    /// would spin forever with nothing reading from it (verified while
    /// hardware-testing the 5s linger -- see `RNDISTransport.close()`'s
    /// doc comment for the full story). Calling `.close()` directly on
    /// `activeTransport` breaks that: it finishes `inbound` immediately,
    /// which ends the pipeline `Task`'s inbound-consumer loop and lets it
    /// complete on its own (its completion handler above then clears
    /// `activeTransport`/`pipelineTask` once `currentTransport == nil`).
    private func teardownHardware() {
        currentSink?.close()
        currentSink = nil
        currentTransport = nil
        activeTransport?.close()
        pipelineTask?.cancel()
    }

    // MARK: - PipelineDelegate (called from the running pipeline Task's
    // thread, never stateQueue -- every method hops onto stateQueue itself)

    func pipeline(didEmitNAL data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        stateQueue.async {
            self.fanOut { $0.nalUnit(data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime) }
        }
    }

    func pipelineDidBeginReceivingVideo() {
        stateQueue.async {
            if self.currentStateValue.rawValue < GogglesState.waitingForKeyframe.rawValue {
                self.setState(.waitingForKeyframe)
            }
        }
    }

    func pipelineDidStart() {
        stateQueue.async { self.setState(.live) }
    }

    func pipelineWentSilent() {
        stateQueue.async {
            if self.everReachedLive, self.currentStateValue == .live {
                self.setState(.stalled, detail: "no data for 2s")
            } else {
                self.setState(.handshaking)
            }
        }
    }

    func pipelineDidUpdateStats(_ stats: PipelineStats) {
        let wire = StreamStats(
            fps: stats.fps,
            bitrateKbps: stats.bitrateKbps,
            drops: stats.drops,
            cumulativeFrames: stats.cumulativeFrames,
            cumulativeBytes: stats.cumulativeBytes,
            cumulativeDrops: stats.cumulativeDrops
        )
        stateQueue.async { self.fanOut { $0.stats(wire) } }
    }
}

enum HelperError: Error {
    case noConnectionContext

    func asNSError() -> NSError {
        switch self {
        case .noConnectionContext:
            return NSError(
                domain: "\(Logging.subsystem).error",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "startStreaming was not called from within an XPC connection context"]
            )
        }
    }
}
