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
// Multi-device picker design (2026-08-29): this type used to hold exactly
// one device's worth of state as flat instance properties
// (`currentStateValue`, `currentDeviceInfoValue`, `everReachedLive`,
// `pipelineGeneration`, `pipelineTask`, `pendingClose`, `lingerTimer`,
// `deviceRetryTimer`, `activeTransport`, `streamingSubscriberIDs`) --
// correct for a helper that could only ever have one device claimed, wrong
// the moment it can claim several at once. All of that is now
// `DeviceState`, one instance per claimed/claiming `deviceId`
// (`GogglesXPC.DeviceInfo.deviceId`), held in `devices: [String:
// DeviceState]`. Every XPC entry point that used to implicitly act on "the"
// device now takes an explicit `deviceId` and looks up (or lazily creates)
// its own `DeviceState` -- this is item 4 of the design's scope, and it's
// what makes item 6 (device-scoped fan-out) possible: each device's
// `streamingSubscriberIDs` is its own set, so `fanOut(deviceId:)` only ever
// reaches the subscribers who actually asked for that device.
//
// One `HelperService` instance is `exportedObject` on every accepted
// `NSXPCConnection` (see `HelperListenerDelegate`); `NSXPCConnection`
// dispatches each exported-object method call on its own connection's
// queue, potentially concurrently across different connections, so every
// piece of mutable state this type owns (including every `DeviceState`) is
// only ever touched from `stateQueue` (a private serial `DispatchQueue`) --
// including from each device's pipeline-delegate adapter's callbacks, which
// arrive from whatever thread that device's running pipeline `Task` happens
// to be on.
//
// Fan-out rule (design §5.5, copied verbatim in the task brief, now scoped
// per device rather than singular):
//   "the helper starts the hardware on the first subscriber that calls
//   startStreaming and tears it down when the last one disconnects, with a
//   5 s linger to survive an app relaunch. Subscribers are independent;
//   one crashing does not stop the others."
// A connection "subscribes" to a device by calling
// `startStreaming(deviceId:)` for it -- `deviceChanged`/`stateChanged`/
// `nalUnit`/`stats` for that device only ever go to connections in that
// device's own `streamingSubscriberIDs`, never to every connected client
// unconditionally (that was fine when there was only ever one possible
// device to talk about; it is not once a client could be looking at a
// different device than another).
// ─────────────────────────────────────────────────────────────────────────

final class HelperService: NSObject, GogglesHelperProtocol {

    private let stateQueue = DispatchQueue(label: "\(Logging.subsystem).state")

    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    /// Task multidevice-picker item 4: everything that used to be flat
    /// per-helper state, now one instance per `deviceId`. Must only be
    /// touched on `stateQueue`.
    private final class DeviceState {
        let deviceId: String

        /// BLOCKER 1 fix (review round 2): what `RNDISTransport
        /// (targetDeviceId:)` actually tries to match right now --
        /// initially equal to `deviceId`, but reassignable by
        /// `resolveMigrationTarget` when `deviceId` is `bus:address`-
        /// derived (no serial) and the device reappears at a different
        /// `bus:address` after a replug/reboot. `deviceId` itself (the
        /// wire-facing identity every client sees) never changes -- see
        /// `DeviceMigration.swift`'s file doc comment for the full
        /// rationale.
        var claimTarget: String

        var streamingSubscriberIDs: Set<ObjectIdentifier> = []

        var pipelineTask: Task<Void, Never>?
        var lingerTimer: DispatchSourceTimer?
        var deviceRetryTimer: DispatchSourceTimer?

        /// The concrete transport `beginStreaming` constructed for this
        /// device. See `RNDISTransport.close()`'s doc comment: the running
        /// pipeline `Task` holds its own strong reference to this same
        /// instance for its entire lifetime, so clearing `handle.transport`
        /// alone never actually stops that `Task` while this daemon process
        /// keeps running -- `teardownHardware` calls `.close()` on this
        /// directly to break that deadlock.
        var activeTransport: RNDISTransport?

        /// This device's `GogglesPipeline.PipelineHandle` (task
        /// multidevice-picker item 3's globals-bug fix) -- the per-device
        /// replacement for what used to be the process-wide
        /// `currentTransport`/`currentSink` globals `requestIFrame` and the
        /// pipeline-completion check used to read. Recreated fresh every
        /// `beginStreaming` call (a stale handle from a superseded
        /// generation must never be read/written by a newer bring-up).
        var handle = PipelineHandle()

        /// Bumped every `beginStreaming` call for this device; lets a
        /// superseded bring-up's own completion handler recognize it's
        /// stale. See the original (pre-multi-device) doc comment on this
        /// field, still accurate, just now per-device.
        var pipelineGeneration = 0

        /// Set by `teardownHardware(deviceId:)` when it hands
        /// `activeTransport.close()` off to a detached `Task`.
        /// `beginStreaming` awaits this before calling `RNDISTransport()`
        /// again for the same device.
        var pendingClose: Task<Void, Never>?

        var currentDeviceInfoValue: GogglesXPC.DeviceInfo?
        var currentStateValue: GogglesState = .noDevice
        var everReachedLive = false

        init(deviceId: String) {
            self.deviceId = deviceId
            self.claimTarget = deviceId
        }
    }

    private var devices: [String: DeviceState] = [:]

    private static let deviceRetryInterval: TimeInterval = 1.0

    // MARK: - Connection bookkeeping (called by HelperListenerDelegate)

    /// Registers a freshly-accepted connection. Multi-device picker design:
    /// unlike the old singular design, a fresh connection has not yet said
    /// which device (if any) it cares about, so there is nothing to
    /// eagerly push here anymore -- the first `deviceChanged`/
    /// `stateChanged` this connection receives for a given device arrives
    /// once it actually calls `startStreaming(deviceId:)` for it (see that
    /// method, which immediately fans out current state to the whole
    /// device's subscriber set including the new arrival).
    func registerConnection(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.connections[id] = connection
            Logging.xpc.info("subscriber connected (\(self.connections.count) total)")
        }
    }

    /// Removes a connection from the general registry and from every
    /// device's streaming-subscriber set on invalidation (crash, force-quit,
    /// explicit `invalidate()`), starting each affected device's 5s
    /// teardown linger if it was that device's last streaming subscriber.
    func unregisterConnection(_ connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            self.connections.removeValue(forKey: id)
            var stillStreamingCount = 0
            for device in self.devices.values {
                let wasStreaming = device.streamingSubscriberIDs.remove(id) != nil
                if wasStreaming {
                    self.scheduleTeardownIfNoSubscribers(device)
                    if device.streamingSubscriberIDs.isEmpty {
                        self.cancelDeviceRetry(device)
                    }
                }
                stillStreamingCount += device.streamingSubscriberIDs.count
            }
            Logging.xpc.info("subscriber disconnected (\(self.connections.count) remaining, \(stillStreamingCount) device-subscriptions remain)")
        }
    }

    private func remoteClient(for connection: NSXPCConnection) -> GogglesClientProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            Logging.xpc.error("remoteObjectProxy error, dropping this subscriber's callback: \(String(describing: error))")
        } as? GogglesClientProtocol
    }

    /// Task multidevice-picker item 6: fan-out scoped to one device's
    /// streaming-subscriber set, never "every connected client" -- the
    /// direct fix for the design's explicit requirement ("a client
    /// subscribed to device A must not receive device B's callbacks").
    /// Must only be called while already executing on `stateQueue`.
    private func fanOut(deviceId: String, _ body: (GogglesClientProtocol) -> Void) {
        guard let device = devices[deviceId] else { return }
        for subscriberId in device.streamingSubscriberIDs {
            guard let connection = connections[subscriberId] else { continue }
            if let proxy = remoteClient(for: connection) {
                body(proxy)
            }
        }
    }

    /// Must only be called while already executing on `stateQueue`.
    private func setState(_ device: DeviceState, _ state: GogglesState, detail: String? = nil) {
        device.currentStateValue = state
        if state == .live { device.everReachedLive = true }
        Logging.pipeline.info("[\(device.deviceId, privacy: .public)] state -> \(String(describing: state)) (\(state.rawValue))\(detail.map { " [\($0)]" } ?? "")")
        fanOut(deviceId: device.deviceId) { $0.stateChanged(device.deviceId, state.rawValue, detail: detail) }
    }

    /// Must only be called while already executing on `stateQueue`. Lazily
    /// creates a device's state on first reference.
    private func deviceState(_ deviceId: String) -> DeviceState {
        if let existing = devices[deviceId] { return existing }
        let created = DeviceState(deviceId: deviceId)
        devices[deviceId] = created
        return created
    }

    // MARK: - GogglesHelperProtocol

    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(currentProtocolVersion)
    }

    /// Multi-device picker design item 2/5: real enumeration (no claim),
    /// off `stateQueue` since `GogglesDeviceEnumerator.enumerate()` makes
    /// blocking libusb calls.
    func enumerateDevices(reply: @escaping ([GogglesXPC.DeviceInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = GogglesDeviceEnumerator.enumerate()
            let wire = found.map { raw in
                GogglesXPC.DeviceInfo(
                    product: raw.product, serial: raw.serial,
                    idVendor: raw.idVendor, idProduct: raw.idProduct, bcdDevice: raw.bcdDevice,
                    bus: raw.bus, address: raw.address
                )
            }
            Logging.usb.info("enumerateDevices: found \(wire.count) candidate(s)")
            reply(wire)
        }
    }

    func currentDeviceInfo(deviceId: String, reply: @escaping (GogglesXPC.DeviceInfo?) -> Void) {
        stateQueue.async { reply(self.devices[deviceId]?.currentDeviceInfoValue) }
    }

    func startStreaming(deviceId: String, reply: @escaping (Bool, NSError?) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(false, HelperError.noConnectionContext.asNSError())
            return
        }
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            let device = self.deviceState(deviceId)
            device.lingerTimer?.cancel()
            device.lingerTimer = nil
            let wasEmpty = device.streamingSubscriberIDs.isEmpty
            device.streamingSubscriberIDs.insert(id)
            Logging.xpc.info("startStreaming(\(deviceId, privacy: .public)) from subscriber (now \(device.streamingSubscriberIDs.count) streaming)")
            // Bring this new/rejoining subscriber up to speed with
            // whatever's already known for this device, mirroring the old
            // singular design's registerConnection behavior -- now done
            // here instead, since which device to push is only known once
            // a subscriber actually asks for one.
            if let proxy = self.remoteClient(for: connection) {
                proxy.deviceChanged(deviceId, device.currentDeviceInfoValue)
                proxy.stateChanged(deviceId, device.currentStateValue.rawValue, detail: nil)
            }
            if wasEmpty, device.pipelineTask == nil {
                self.cancelDeviceRetry(device)
                self.beginStreaming(device, reply: reply)
            } else {
                // Hardware already up (or in the middle of coming up) for
                // an earlier subscriber -- this one just joins the fan-out
                // it's already registered for above.
                reply(true, nil)
            }
        }
    }

    func stopStreaming(deviceId: String, reply: @escaping () -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply()
            return
        }
        let id = ObjectIdentifier(connection)
        stateQueue.async {
            guard let device = self.devices[deviceId] else {
                reply()
                return
            }
            device.streamingSubscriberIDs.remove(id)
            Logging.xpc.info("stopStreaming(\(deviceId, privacy: .public)) from subscriber (\(device.streamingSubscriberIDs.count) streaming remain)")
            self.scheduleTeardownIfNoSubscribers(device)
            if device.streamingSubscriberIDs.isEmpty {
                self.cancelDeviceRetry(device)
            }
            reply()
        }
    }

    func requestIFrame(deviceId: String, reply: @escaping () -> Void) {
        stateQueue.async {
            // Best-effort (design §8.1): the goggles' DUML 02:B3 handling
            // is unreliable even on its own regular 1.5s retry cadence
            // (which `runPipeline` already drives internally); this is
            // just an extra nudge on top, sent with a fresh session id
            // since the pipeline's own in-flight session id isn't exposed
            // outside its running Task. No failure is ever reported --
            // matches the protocol's documented contract.
            //
            // Task multidevice-picker item 3: reads this device's own
            // `PipelineHandle.transport`, not the old process-wide
            // `currentTransport` global -- the fix that makes this call
            // safe under multi-claim (device A's requestIFrame can no
            // longer land on device B's transport).
            if let transport = self.devices[deviceId]?.handle.transport {
                let seq = WireProtocol.randomSessionId()
                let sessionId = WireProtocol.randomSessionId()
                try? transport.send(WireProtocol.requestIFrameTelemetry(seq: seq, sessionId: sessionId))
                Logging.pipeline.info("requestIFrame(\(deviceId, privacy: .public)): sent best-effort DUML 02:B3 nudge")
            } else {
                Logging.pipeline.info("requestIFrame(\(deviceId, privacy: .public)): no active transport, ignoring")
            }
            reply()
        }
    }

    func reconnect(deviceId: String, reply: @escaping () -> Void) {
        stateQueue.async {
            Logging.usb.info("reconnect(\(deviceId, privacy: .public)) requested: full teardown + design §5.1 rerun")
            let device = self.deviceState(deviceId)
            device.lingerTimer?.cancel()
            device.lingerTimer = nil
            self.cancelDeviceRetry(device)
            self.teardownHardware(device)
            if device.streamingSubscriberIDs.isEmpty {
                self.setState(device, .noDevice)
                reply()
            } else {
                self.beginStreaming(device, reply: { _, _ in })
                reply()
            }
        }
    }

    // MARK: - Hardware lifecycle (must only run on stateQueue)

    /// Brings one device's hardware up: claims IF0/IF1 + RNDIS init + ARP
    /// resolve (all inside `RNDISTransport.init(targetDeviceId:)`, design
    /// §5.1), then starts the shared pipeline
    /// (`GogglesPipeline.runPipeline`) with a per-device delegate adapter.
    /// `RNDISTransport()` is a blocking call, so it runs on a detached Task
    /// rather than blocking `stateQueue`.
    private func beginStreaming(_ device: DeviceState, reply: @escaping (Bool, NSError?) -> Void, announceClaiming: Bool = true) {
        if announceClaiming {
            setState(device, .claiming)
        }
        device.pipelineGeneration += 1
        let myGeneration = device.pipelineGeneration
        let priorClose = device.pendingClose
        device.pendingClose = nil
        let deviceId = device.deviceId
        let claimTarget = device.claimTarget
        let newHandle = PipelineHandle()
        device.handle = newHandle
        Logging.usb.info("[\(deviceId, privacy: .public)] claiming IF0/IF1 and bringing up RNDIS (claim target: \(claimTarget, privacy: .public))...")
        Task.detached { [weak self] in
            guard let self else { return }
            await priorClose?.value
            do {
                let transport = try RNDISTransport(targetDeviceId: claimTarget)
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
                Logging.usb.info("[\(deviceId, privacy: .public)] claimed IF0/IF1, device: \(raw.product ?? "?", privacy: .public)")
                self.stateQueue.async {
                    guard device.pipelineGeneration == myGeneration else { return }
                    device.activeTransport = transport
                    device.currentDeviceInfoValue = info
                    self.fanOut(deviceId: deviceId) { $0.deviceChanged(deviceId, info) }
                    self.setState(device, .handshaking)
                    reply(true, nil)
                }
                let adapter = DevicePipelineDelegateAdapter(service: self, deviceId: deviceId)
                let task = Task {
                    do {
                        try await runPipeline(transport: transport, sink: nil, stats: false, delegate: adapter, handle: newHandle)
                        Logging.pipeline.info("[\(deviceId, privacy: .public)] runPipeline returned (transport released, e.g. unplug or teardown)")
                    } catch {
                        Logging.pipeline.error("[\(deviceId, privacy: .public)] runPipeline ended with error: \(String(describing: error))")
                    }
                    self.stateQueue.async {
                        // Stale (superseded by a later beginStreaming, e.g.
                        // reconnect()) -- don't clobber the newer bring-up's
                        // state.
                        guard device.pipelineGeneration == myGeneration else { return }
                        device.pipelineTask = nil
                        // LOW cleanup (review round 2): this used to be
                        // gated behind `if newHandle.transport == nil`, but
                        // by the time this closure runs, `runPipeline`'s own
                        // `defer` (Pipeline.swift) has unconditionally
                        // already nilled `newHandle.transport` -- and the
                        // `pipelineGeneration` guard above already confirms
                        // `newHandle` is still this device's current handle
                        // (not superseded), so the check was always `true`
                        // here, just misleadingly so. Removed; the
                        // generation guard is the real, meaningful gate.
                        device.activeTransport = nil
                        device.currentDeviceInfoValue = nil
                        self.setState(device, .noDevice)
                        // Task 3.7, design §9.3 scenario 1/2: the
                        // pipeline just ended because the transport
                        // went away. If a subscriber is still
                        // streaming this device, it still wants video;
                        // poll for the replug.
                        self.scheduleDeviceRetry(device)
                    }
                }
                self.stateQueue.async {
                    guard device.pipelineGeneration == myGeneration else { return }
                    device.pipelineTask = task
                }
            } catch {
                let nsError = error as NSError
                Logging.usb.error("[\(deviceId, privacy: .public)] claim/RNDIS bring-up failed: \(String(describing: error))")

                // BLOCKER 1 fix (review round 2): before assuming "genuinely
                // not there right now", check whether this is actually a
                // bus:address-derived device that reappeared under a
                // *different* bus:address (unplug/replug, or a goggles
                // reboot -- both re-enumerate with a fresh address; a
                // reboot can also rotate the RNDIS MAC, unrelated and
                // already handled separately by `ARPResolver`). Safe to do
                // here (still off `stateQueue`, inside `Task.detached`) --
                // `resolveMigrationTarget` makes its own blocking
                // `GogglesDeviceEnumerator.enumerate()` call, which must
                // never run on `stateQueue`.
                var migratedTarget: String?
                if case RNDISTransportError.deviceNotFound = error, DeviceMigration.isBusAddressDerived(deviceId) {
                    migratedTarget = self.resolveMigrationTarget(forDeviceId: deviceId, staleClaimTarget: claimTarget)
                    if let migratedTarget {
                        Logging.usb.info("[\(deviceId, privacy: .public)] migrating claim target \(claimTarget, privacy: .public) -> \(migratedTarget, privacy: .public) (likely a replug/reboot changed this device's bus:address)")
                    }
                }

                self.stateQueue.async {
                    guard device.pipelineGeneration == myGeneration else { return }
                    device.pipelineTask = nil
                    if case RNDISTransportError.deviceNotFound = error {
                        // Task 3.7, design §9.3 scenarios 2/3: not
                        // necessarily a genuine claim failure -- there's
                        // just no `2CA3:0020` matching `claimTarget` on the
                        // bus right now (possibly because `claimTarget` was
                        // just migrated above and hasn't been retried yet).
                        //
                        // Guarded (task 3.8 bug fix): a background retry
                        // poll (`announceClaiming == false`) that finds
                        // nothing never left `.noDevice` in the first place,
                        // so re-sending the identical `.noDevice` here would
                        // be a no-op state-wise but still fan out a
                        // redundant `stateChanged` call once a second,
                        // forever, for no observable benefit.
                        if let migratedTarget {
                            // Only meaningful if a newer beginStreaming
                            // hasn't already superseded this generation --
                            // the outer guard above already ensures that.
                            device.claimTarget = migratedTarget
                        }
                        if device.currentStateValue != .noDevice {
                            self.setState(device, .noDevice)
                        }
                        reply(true, nil)
                        self.scheduleDeviceRetry(device)
                    } else {
                        self.setState(device, .claimFailed, detail: nsError.localizedDescription)
                        reply(false, nsError)
                    }
                }
            }
        }
    }

    /// BLOCKER 1 fix (review round 2): must only be called OFF
    /// `stateQueue` (it makes a blocking `GogglesDeviceEnumerator
    /// .enumerate()` libusb call) -- safe from inside `beginStreaming`'s
    /// `Task.detached` body, which is exactly its one call site. Takes a
    /// brief `stateQueue.sync` snapshot of the other devices' claim
    /// targets (cheap, no libusb call inside that block) before the
    /// blocking enumerate call.
    private func resolveMigrationTarget(forDeviceId deviceId: String, staleClaimTarget: String) -> String? {
        let otherTargets: Set<String> = stateQueue.sync {
            Set(self.devices.values.filter { $0.deviceId != deviceId }.map(\.claimTarget))
        }
        let candidates = GogglesDeviceEnumerator.enumerate().map(\.deviceId)
        return DeviceMigration.chooseMigrationTarget(
            currentTarget: staleClaimTarget,
            enumeratedCandidateIds: candidates,
            otherKnownClaimTargets: otherTargets
        )
    }

    /// Schedules a `beginStreaming()` retry for one device after
    /// `deviceRetryInterval`. A no-op if one's already pending for this
    /// device, or if nothing is actually streaming it.
    private func scheduleDeviceRetry(_ device: DeviceState) {
        guard device.deviceRetryTimer == nil, !device.streamingSubscriberIDs.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + Self.deviceRetryInterval)
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device else { return }
            device.deviceRetryTimer = nil
            guard !device.streamingSubscriberIDs.isEmpty, device.pipelineTask == nil else { return }
            Logging.usb.info("[\(device.deviceId, privacy: .public)] device retry: polling for goggles on USB again")
            self.beginStreaming(device, reply: { _, _ in }, announceClaiming: false)
        }
        timer.resume()
        device.deviceRetryTimer = timer
    }

    /// Cancels any pending device-retry poll for one device.
    private func cancelDeviceRetry(_ device: DeviceState) {
        device.deviceRetryTimer?.cancel()
        device.deviceRetryTimer = nil
    }

    /// Starts one device's 5s linger (design §5.5) once its
    /// streaming-subscriber set goes empty, unless one is already pending.
    private func scheduleTeardownIfNoSubscribers(_ device: DeviceState) {
        guard device.streamingSubscriberIDs.isEmpty,
              device.pipelineTask != nil || device.handle.transport != nil,
              device.lingerTimer == nil else {
            return
        }
        Logging.xpc.info("[\(device.deviceId, privacy: .public)] no streaming subscribers left; starting 5s teardown linger")
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device else { return }
            device.lingerTimer = nil
            guard device.streamingSubscriberIDs.isEmpty else {
                Logging.xpc.info("[\(device.deviceId, privacy: .public)] linger expired but a subscriber reconnected; keeping hardware up")
                return
            }
            Logging.usb.info("[\(device.deviceId, privacy: .public)] linger expired with no subscribers; releasing USB interfaces")
            self.teardownHardware(device)
            self.setState(device, .noDevice)
            // Deliberately NOT removing this entry from `devices` here.
            // `teardownHardware` starts an ASYNC `transport.close()` and
            // parks it in `device.pendingClose` -- at this exact point
            // that close is still in flight, so this `DeviceState` is not
            // yet fully idle. `beginStreaming` serializes reopen-after-
            // close by awaiting `priorClose` on the SAME `DeviceState`
            // instance; removing the entry here would make a fast
            // relaunch land on a freshly-recreated `DeviceState` with no
            // `pendingClose`, bypassing that serialization and racing the
            // in-flight `libusb` interface release (review round 2,
            // finding 1 -- this was unrequested scope creep the first
            // time and made the single-device teardown/reopen path worse,
            // not better; reverted rather than re-guarded).
        }
        timer.resume()
        device.lingerTimer = timer
    }

    /// Releases one device's USB interfaces while this daemon process keeps
    /// running (and keeps every other device's pipeline untouched). See the
    /// original (pre-multi-device) doc comment on this method for the full
    /// rationale on why `activeTransport.close()` (not just clearing
    /// references) is what actually stops the running pipeline `Task`.
    private func teardownHardware(_ device: DeviceState) {
        device.handle.releaseSynchronously()
        device.pipelineTask?.cancel()
        device.pipelineTask = nil
        let transport = device.activeTransport
        device.activeTransport = nil
        if let transport {
            Logging.usb.info("[\(device.deviceId, privacy: .public)] releasing USB interfaces off stateQueue...")
            device.pendingClose = Task.detached {
                transport.close()
            }
        }
    }

    // MARK: - Pipeline-delegate callbacks (called from
    // DevicePipelineDelegateAdapter, from the running pipeline Task's
    // thread, never stateQueue -- every method hops onto stateQueue itself)

    fileprivate func pipelineDidEmitNAL(deviceId: String, data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        stateQueue.async {
            guard let device = self.devices[deviceId] else { return }
            // Task 3.7, design §9.3 scenario 4: see the original (pre-
            // multi-device) doc comment on this recovery check -- unchanged
            // logic, now against this device's own state instead of the
            // helper's singular state.
            if device.everReachedLive, device.currentStateValue == .stalled || device.currentStateValue == .handshaking {
                self.setState(device, .live)
            }
            self.fanOut(deviceId: deviceId) { $0.nalUnit(deviceId, data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime) }
        }
    }

    fileprivate func pipelineDidBeginReceivingVideo(deviceId: String) {
        stateQueue.async {
            let device = self.deviceState(deviceId)
            if device.currentStateValue.rawValue < GogglesState.waitingForKeyframe.rawValue {
                self.setState(device, .waitingForKeyframe)
            }
        }
    }

    fileprivate func pipelineDidStart(deviceId: String) {
        stateQueue.async { self.setState(self.deviceState(deviceId), .live) }
    }

    fileprivate func pipelineWentSilent(deviceId: String) {
        stateQueue.async {
            let device = self.deviceState(deviceId)
            if device.everReachedLive, device.currentStateValue == .live {
                self.setState(device, .stalled, detail: "no data for 2s")
            } else {
                self.setState(device, .handshaking)
            }
        }
    }

    fileprivate func pipelineDidUpdateStats(deviceId: String, _ stats: PipelineStats) {
        let wire = StreamStats(
            fps: stats.fps,
            bitrateKbps: stats.bitrateKbps,
            drops: stats.drops,
            cumulativeFrames: stats.cumulativeFrames,
            cumulativeBytes: stats.cumulativeBytes,
            cumulativeDrops: stats.cumulativeDrops
        )
        stateQueue.async { self.fanOut(deviceId: deviceId) { $0.stats(deviceId, wire) } }
    }
}

/// Task multidevice-picker item 4: `HelperService` can now run several
/// concurrent pipelines (one per claimed device), but `PipelineDelegate`'s
/// methods carry no device context of their own -- `runPipeline` was built
/// (task 2.2) around exactly one delegate per process. Rather than change
/// `GogglesPipeline`'s public delegate protocol (a churn-inducing change to
/// a package `gvcli` also depends on, for no benefit to `gvcli` itself,
/// which never runs more than one pipeline), each device gets its own small
/// adapter instance that closes over `deviceId` and forwards to
/// `HelperService`'s own (differently-named, deviceId-taking) methods.
private final class DevicePipelineDelegateAdapter: PipelineDelegate {
    private weak var service: HelperService?
    private let deviceId: String

    init(service: HelperService, deviceId: String) {
        self.service = service
        self.deviceId = deviceId
    }

    func pipeline(didEmitNAL data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        service?.pipelineDidEmitNAL(deviceId: deviceId, data: data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }

    func pipelineDidBeginReceivingVideo() {
        service?.pipelineDidBeginReceivingVideo(deviceId: deviceId)
    }

    func pipelineDidStart() {
        service?.pipelineDidStart(deviceId: deviceId)
    }

    func pipelineWentSilent() {
        service?.pipelineWentSilent(deviceId: deviceId)
    }

    func pipelineDidUpdateStats(_ stats: PipelineStats) {
        service?.pipelineDidUpdateStats(deviceId: deviceId, stats)
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
