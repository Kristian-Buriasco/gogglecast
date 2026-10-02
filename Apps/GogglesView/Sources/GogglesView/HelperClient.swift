import Foundation
import GogglesXPC

// ─────────────────────────────────────────────────────────────────────────
// Task 3.1: the app's XPC client layer. `HelperClient` owns the
// `NSXPCConnection` to `GogglesHelper` (design §5.5), exports a
// `GogglesClientProtocol` object so the helper can call back
// `deviceChanged`/`stateChanged`/`nalUnit`/`stats`, checks
// `protocolVersion(reply:)` against `GogglesXPC.currentProtocolVersion` on
// every fresh connection, and reconnects on invalidation.
//
// `.privileged` vs empty `options:` -- resolved, not guessed:
// -----------------------------------------------------------------------
// The task brief explicitly asks this to be *verified*, not assumed, since
// design.md §4.4 commits to `.privileged` but Task 2.4's own throwaway XPC
// test client (see its report) used `options: []` and that worked too.
// Checked Apple's actual `NSXPCConnection.h` header comment for
// `machServiceName:options:` (not blog posts, not the empty online API
// reference page for `NSXPCConnection.Options`, which has no discussion
// text at all): "Use this if looking up a name advertised in a
// launchd.plist... If the connection is being made to something in a
// privileged Mach bootstrap (for example, a daemon with a launchd.plist in
// /Library/LaunchDaemons), then use the NSXPCConnectionPrivileged option."
//
// `GogglesHelper` is installed via `SMAppService.daemon`, which places its
// plist at `/Library/LaunchDaemons/com.kburiasco.gogglesview.helper.plist`
// (Task 2.3) -- i.e. exactly "a daemon with a launchd.plist in
// /Library/LaunchDaemons", the privileged Mach bootstrap namespace, as
// opposed to a per-user LaunchAgent. `.privileged` is the option that
// header comment describes for precisely this case -- it is not an
// SMJobBless-only relic (SMJobBless is one *caller* of that pattern, not
// the whole of what the flag means). Task 2.4's `options: []` client also
// connecting successfully doesn't contradict this: `bootstrap_look_up`
// can still resolve the service either way on this machine's setup, but
// `.privileged` is the documented-correct, semantically honest option for
// a LaunchDaemon target, matches design.md's explicit commitment, and is
// what this file uses.
// ─────────────────────────────────────────────────────────────────────────

/// This client's local view of connection health, layered on top of the
/// helper's own `GogglesState` (design §6, which describes *device/stream*
/// state and has no case for "the app and helper speak incompatible XPC
/// protocol versions" -- that's a client-side concern the helper can't
/// even express in its own state machine). No SwiftUI consumer exists yet
/// (Task 3.4+); this enum is the "loud, visible error state" the brief
/// asks for in the meantime, and the seam a future state machine plugs
/// into.
public enum HelperClientConnectionState: Equatable, Sendable {
    /// No connection attempt in flight or established.
    case disconnected
    /// `NSXPCConnection` created and resumed; awaiting the initial
    /// `protocolVersion(reply:)` round trip.
    case connecting
    /// Connected and protocol versions match.
    case connected
    /// Connected, but the helper reported a `protocolVersion` different
    /// from `GogglesXPC.currentProtocolVersion` -- the "fails loudly" case
    /// the brief calls for. The connection is intentionally left open
    /// (still relaying `deviceChanged`/`stateChanged`, which are unlikely
    /// to change shape across a version bump) so the eventual UI has
    /// something to show, but `HelperClient` refuses to call
    /// `startStreaming` while in this state (see `startStreaming(reply:)`)
    /// since NAL/stream semantics are exactly what a version bump most
    /// plausibly changed.
    case versionMismatch(reported: Int, expected: Int)
}

public extension HelperClientConnectionState {
    /// BLOCKER 2 fix (multi-device picker review round 2): the
    /// `GogglesUIState.noHelper(reason:)`-style reason text this
    /// connection state implies, if any. Extracted here (not forked
    /// between call sites) so `GogglesConnectionCoordinator`'s existing
    /// loud-failure mapping and `DevicePickerCoordinator`'s own copy of
    /// the same failure (surfaced during the device-selection phase, which
    /// runs BEFORE any `GogglesConnectionCoordinator` exists to show it)
    /// are guaranteed to say the exact same thing. `nil` for
    /// `.connecting`/`.disconnected` (a real "no helper" case, but with no
    /// extra detail beyond the state itself) and for `.connected` (nothing
    /// to report -- see `isHelperUnavailable` for that check).
    var noHelperReasonText: String? {
        guard case .versionMismatch(let reported, let expected) = self else { return nil }
        return "helper protocol version \(reported) does not match app's \(expected) -- reinstall/update the helper or the app"
    }

    /// `true` for every state except `.connected` -- i.e. "the helper
    /// can't be used right now for some reason", the same condition both
    /// `GogglesConnectionCoordinator` and `DevicePickerCoordinator` gate
    /// their loud-failure display on.
    var isHelperUnavailable: Bool {
        if case .connected = self { return false }
        return true
    }
}

/// The app's XPC client to `GogglesHelper` (design §5.5). One instance per
/// subscriber "slot" the app wants -- Task 3.1's own test harness
/// (`main.swift --test-client`) uses exactly one; a later menu-bar UI would
/// most likely also use exactly one, shared across whatever windows it
/// drives, though nothing here assumes a singleton.
public final class HelperClient: NSObject {

    // MARK: - Public callback surface
    //
    // Plain closures, not a delegate protocol: there's no SwiftUI consumer
    // yet (Task 3.4+ builds that), and a closure-based surface is the
    // smallest thing that lets `main.swift`'s `--test-client` harness
    // observe what's happening without inventing a delegate protocol this
    // task's brief doesn't ask for and a later task would likely replace
    // anyway. All four fire on the main queue (see each handle* method)
    // so a future SwiftUI/AppKit consumer never has to hop threads itself.

    public var onConnectionStateChange: ((HelperClientConnectionState) -> Void)?
    public var onDeviceChanged: ((DeviceInfo?) -> Void)?
    public var onHelperStateChanged: ((Int, String?) -> Void)?
    public var onStats: ((StreamStats) -> Void)?
    /// Task 3.3: the raw per-NAL callback, verbatim from `GogglesClientProtocol.nalUnit`
    /// (one complete Annex-B start-code-prefixed NAL per call -- confirmed
    /// against `HelperService.pipeline(didEmitNAL:...)` /
    /// `GogglesPipeline/Pipeline.swift`, which emits exactly one NAL per
    /// `delegate?.pipeline(didEmitNAL:...)` call, not a multi-NAL blob).
    /// `DecodeSession` is the intended consumer. Kept separate from
    /// `NALFPSCounter`'s bookkeeping (`handleNALUnit` below still drives
    /// that unconditionally) so a client with no interest in decoding
    /// (e.g. a future stats-only observer) isn't forced to pay for it.
    public var onNALUnit: ((Data, UInt8, Bool, UInt64) -> Void)?

    public private(set) var connectionState: HelperClientConnectionState = .disconnected {
        didSet {
            guard connectionState != oldValue else { return }
            let state = connectionState
            let handler = onConnectionStateChange
            DispatchQueue.main.async { handler?(state) }
        }
    }

    // MARK: - Internals

    private let machServiceName: String
    private let reconnectDelay: TimeInterval
    /// Every mutable-state access below (`connection`, `exportedClient`,
    /// `reconnectWorkItem`, `connectionState`) only ever happens on this
    /// queue -- mirrors `HelperService.stateQueue`'s reasoning exactly:
    /// `NSXPCConnection`'s handlers (`invalidationHandler`,
    /// `interruptionHandler`) and the exported object's callback methods
    /// can all fire concurrently/off the calling thread.
    private let stateQueue = DispatchQueue(label: "\(Logging.subsystem).client.helperclient.state")

    private var connection: NSXPCConnection?
    private var exportedClient: ExportedClient?
    private var reconnectWorkItem: DispatchWorkItem?
    /// Set once `connect()` has been called; `disconnect()` clears it so a
    /// pending/in-flight reconnect (scheduled by an invalidation that
    /// raced an explicit `disconnect()`) doesn't resurrect a connection
    /// the caller asked to tear down.
    private var wantsConnected = false

    /// Multi-device picker design item 5/7: the `deviceId` this client last
    /// called `startStreaming(deviceId:)` for, if any. Every incoming
    /// `GogglesClientProtocol` callback carries its own `deviceId` now
    /// (design item 6) -- the helper's fan-out is already scoped so a
    /// callback for a different device should never arrive here, but this
    /// is checked defensively (a stale callback racing a device switch is
    /// the one scenario where it could) so `on*` closures never receive a
    /// value for a device this client didn't ask about. `nil` before the
    /// first `startStreaming(deviceId:)` call, or after `disconnect()`.
    ///
    /// Guarded by its own lock (not `stateQueue`): written from
    /// `stateQueue` in `startStreaming`/`disconnect`, read from whatever
    /// thread each `GogglesClientProtocol` callback arrives on (including
    /// the per-NAL hot path) -- a `stateQueue.sync` per NAL would add
    /// unnecessary latency there for a single-word read.
    private let streamingDeviceIdLock = NSLock()
    private var _streamingDeviceId: String?
    private var streamingDeviceId: String? {
        get { streamingDeviceIdLock.lock(); defer { streamingDeviceIdLock.unlock() }; return _streamingDeviceId }
        set { streamingDeviceIdLock.lock(); _streamingDeviceId = newValue; streamingDeviceIdLock.unlock() }
    }

    private let fpsCounter = NALFPSCounter()

    /// - Parameters:
    ///   - machServiceName: defaults to the real, verified helper service
    ///     name (`MachService.swift`); overridable for tests, though the
    ///     version-mismatch unit test in `HelperClientTests.swift`
    ///     exercises the pure comparison logic directly rather than
    ///     standing up a fake XPC listener.
    ///   - reconnectDelay: brief explicitly leaves this undesigned ("use
    ///     reasonable judgment -- e.g. a short delay and retry, not a
    ///     tight loop"). 2s chosen: long enough that a helper mid-restart
    ///     (launchd relaunching it after a crash, or this machine's own
    ///     rebuild-and-relaunch cycle documented in docs/dev-setup.md)
    ///     isn't hammered with connection attempts, short enough that a
    ///     human watching `--test-client`'s console output doesn't
    ///     perceive a stall. Not exponential backoff: this app talks to
    ///     exactly one fixed, local, launchd-supervised Mach service, not
    ///     an unreliable remote endpoint -- unbounded backoff would only
    ///     make recovery from a momentary helper restart feel slower than
    ///     it needs to for no corresponding benefit.
    public init(machServiceName: String = helperMachServiceName, reconnectDelay: TimeInterval = 2.0) {
        self.machServiceName = machServiceName
        self.reconnectDelay = reconnectDelay
        super.init()
    }

    deinit {
        reconnectWorkItem?.cancel()
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    // MARK: - Public API

    /// Creates and resumes the `NSXPCConnection`, then checks
    /// `protocolVersion`. Safe to call once; reconnection after
    /// invalidation is automatic and does not need another call to this.
    public func connect() {
        stateQueue.async {
            self.wantsConnected = true
            self.connectLocked()
        }
    }

    /// Explicit, permanent teardown -- cancels any pending reconnect and
    /// invalidates the live connection (if any). `connectionState` becomes
    /// `.disconnected` and stays there until `connect()` is called again.
    public func disconnect() {
        stateQueue.async {
            self.wantsConnected = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.fpsCounter.stop()
            self.connection?.invalidationHandler = nil
            self.connection?.interruptionHandler = nil
            self.connection?.invalidate()
            self.connection = nil
            self.exportedClient = nil
            self.connectionState = .disconnected
            self.streamingDeviceId = nil
        }
    }

    /// Multi-device picker design item 5/7: lists every currently-connected
    /// device (no claim) -- the app calls this to decide whether to go
    /// straight to the single-device path or show a picker. Forwards
    /// straight to `GogglesHelperProtocol.enumerateDevices(reply:)`;
    /// replies `[]` (no XPC round trip) if not currently connected, same
    /// "fail toward the least presumptuous answer" pattern as every other
    /// call here.
    public func enumerateDevices(reply: @escaping ([DeviceInfo]) -> Void) {
        // MEDIUM 6 fix (multi-device picker review round 2): test seam, not
        // used by production code -- when set, calls straight through
        // instead of going through the real (necessarily-not-connected-in-
        // tests) XPC proxy. This lets `DevicePickerCoordinatorTests` drive
        // `DevicePickerCoordinator`'s real `poll()` mechanism end-to-end
        // (including the auto-select-on-exactly-one-candidate branch --
        // the single-device regression path, this session's own primary
        // verifiable-without-hardware coverage) instead of hand-
        // constructing expected values and never actually exercising the
        // coordinator's polling code. Synchronous (no dispatch) so tests
        // don't need to pump a run loop/sleep to observe the result.
        if let override = enumerateDevicesOverrideForTesting {
            reply(override())
            return
        }
        stateQueue.async {
            guard let proxy = self.remoteHelperProxy() else {
                DispatchQueue.main.async { reply([]) }
                return
            }
            proxy.enumerateDevices { infos in
                DispatchQueue.main.async { reply(infos) }
            }
        }
    }

    /// See `enumerateDevices(reply:)`'s doc comment. `internal`, not
    /// `private`, so `GogglesViewTests` (same module, `@testable import`)
    /// can set it.
    var enumerateDevicesOverrideForTesting: (() -> [DeviceInfo])?

    /// Forwards to `GogglesHelperProtocol.startStreaming(deviceId:reply:)`.
    /// Refuses (with a synthetic error, no XPC round trip) while
    /// `connectionState` is `.versionMismatch` or not yet `.connected` --
    /// see `HelperClientConnectionState.versionMismatch`'s doc comment for
    /// why streaming specifically is the thing gated here.
    public func startStreaming(deviceId: String, reply: @escaping (Bool, NSError?) -> Void) {
        stateQueue.async {
            guard self.connectionState == .connected, let proxy = self.remoteHelperProxy() else {
                let detail: String
                switch self.connectionState {
                case .versionMismatch(let reported, let expected):
                    detail = "refusing startStreaming: protocol version mismatch (helper=\(reported), app expects \(expected))"
                default:
                    detail = "refusing startStreaming: not connected (state=\(self.connectionState))"
                }
                Logging.xpc.fault("\(detail, privacy: .public)")
                let error = NSError(
                    domain: "\(Logging.subsystem).error",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: detail]
                )
                DispatchQueue.main.async { reply(false, error) }
                return
            }
            self.streamingDeviceId = deviceId
            self.fpsCounter.start()
            proxy.startStreaming(deviceId: deviceId) { ok, error in
                DispatchQueue.main.async { reply(ok, error) }
            }
        }
    }

    public func stopStreaming(deviceId: String, reply: @escaping () -> Void = {}) {
        stateQueue.async {
            self.fpsCounter.stop()
            guard let proxy = self.remoteHelperProxy() else {
                DispatchQueue.main.async { reply() }
                return
            }
            proxy.stopStreaming(deviceId: deviceId) {
                DispatchQueue.main.async { reply() }
            }
        }
    }

    public func requestIFrame(deviceId: String, reply: @escaping () -> Void = {}) {
        stateQueue.async {
            guard let proxy = self.remoteHelperProxy() else {
                DispatchQueue.main.async { reply() }
                return
            }
            proxy.requestIFrame(deviceId: deviceId) { DispatchQueue.main.async { reply() } }
        }
    }

    public func reconnectHelper(deviceId: String, reply: @escaping () -> Void = {}) {
        stateQueue.async {
            guard let proxy = self.remoteHelperProxy() else {
                DispatchQueue.main.async { reply() }
                return
            }
            proxy.reconnect(deviceId: deviceId) { DispatchQueue.main.async { reply() } }
        }
    }

    // MARK: - Connection setup (must only run on stateQueue)

    private func connectLocked() {
        guard wantsConnected else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connectionState = .connecting

        let newConnection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        let helperInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        // Real bug found live (multi-device hardware testing): unlike a
        // single custom NSSecureCoding-conforming parameter/reply (which
        // NSXPCInterface can auto-derive the allowed class from the
        // Objective-C method signature), an ARRAY of one -- here,
        // `enumerateDevices(reply: ([DeviceInfo]) -> Void)`'s
        // `[DeviceInfo]` reply -- is never auto-whitelisted. Without this,
        // the connection logs "Exception caught during decoding of reply
        // to message 'enumerateDevicesWithReply:', dropping incoming
        // message" on every call and the picker never sees any candidate,
        // even though the helper-side enumeration itself succeeds (visible
        // in its own log as "found N candidate(s)") -- the failure is
        // purely in the client decoding the reply, hence this is set on
        // `remoteObjectInterface`, not the helper's `exportedInterface`.
        helperInterface.setClasses(
            NSSet(array: [NSArray.self, DeviceInfo.self]) as! Set<AnyHashable>,
            for: #selector(GogglesHelperProtocol.enumerateDevices(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        newConnection.remoteObjectInterface = helperInterface
        newConnection.exportedInterface = NSXPCInterface(with: GogglesClientProtocol.self)

        let exported = ExportedClient()
        exported.owner = self
        newConnection.exportedObject = exported
        self.exportedClient = exported

        // Weak captures: the connection object owns these closures, so a
        // strong capture of `newConnection` would be a retain cycle
        // (mirrors `HelperListenerDelegate`'s identical reasoning on the
        // helper side).
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            Logging.xpc.error("XPC connection invalidated")
            self?.handleInvalidation(newConnection)
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            // Task 3.7, design §9.3 scenario 5 (`sudo killall GogglesHelper`
            // while live): the doc comment this replaced assumed
            // invalidation reliably follows an interruption for a
            // launchd/`SMAppService` Mach service. Verified against real
            // hardware that this assumption is false, at least for a clean
            // SIGTERM exit (as opposed to a genuine crash) -- interruption
            // fired exactly once and invalidation never followed, even
            // after 90+ seconds, leaving this connection permanently
            // wedged (every future call just fails silently) with no
            // reconnect ever scheduled, since `handleInvalidation` is the
            // only thing that schedules one. A completely separate fresh
            // process connecting to the same Mach service in the meantime
            // connected and worked immediately, proving the daemon itself
            // was respawning fine -- this was purely a client-side gap.
            //
            // Fix: explicitly invalidate here. `NSXPCConnection.invalidate()`
            // is documented safe to call multiple times/redundantly (a
            // later real invalidation, if it ever does arrive on this same
            // object, is a harmless no-op via `handleInvalidation`'s own
            // `invalidatedConnection === self.connection` guard), and it
            // reliably drives `invalidationHandler` -> `handleInvalidation`
            // -> the existing, already-correct 2s-delay reconnect loop.
            Logging.xpc.error("XPC connection interrupted (helper process likely restarted) -- invalidating to force reconnect")
            newConnection?.invalidate()
        }

        connection = newConnection
        newConnection.resume()
        Logging.xpc.info("XPC connection resumed, checking protocolVersion...")
        verifyProtocolVersion(on: newConnection)
    }

    private func handleInvalidation(_ invalidatedConnection: NSXPCConnection?) {
        stateQueue.async { [self] in
            // Ignore invalidation callbacks from a connection object that
            // isn't the one we currently care about (e.g. a stale
            // callback from a connection `disconnect()` already tore down
            // and replaced).
            guard invalidatedConnection === self.connection || invalidatedConnection == nil else { return }
            self.connection = nil
            self.exportedClient = nil
            self.fpsCounter.stop()
            self.connectionState = .disconnected
            guard self.wantsConnected else { return }
            Logging.xpc.info("scheduling reconnect in \(self.reconnectDelay, format: .fixed(precision: 1))s")
            let work = DispatchWorkItem { [weak self] in self?.connectLocked() }
            self.reconnectWorkItem = work
            self.stateQueue.asyncAfter(deadline: .now() + self.reconnectDelay, execute: work)
        }
    }

    /// Must only be called while already executing on `stateQueue`.
    private func remoteHelperProxy() -> GogglesHelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            Logging.xpc.error("remoteObjectProxy error: \(String(describing: error), privacy: .public)")
        } as? GogglesHelperProtocol
    }

    /// Must only be called while already executing on `stateQueue`, with
    /// `connection` already assigned to `theConnection`.
    private func verifyProtocolVersion(on theConnection: NSXPCConnection) {
        guard let proxy = theConnection.remoteObjectProxyWithErrorHandler({ error in
            Logging.xpc.error("protocolVersion round trip failed: \(String(describing: error), privacy: .public)")
        }) as? GogglesHelperProtocol else {
            Logging.xpc.fault("could not obtain GogglesHelperProtocol proxy for protocolVersion check")
            return
        }
        proxy.protocolVersion { [weak self] reported in
            guard let self else { return }
            self.stateQueue.async {
                // Stale reply from a connection that's since been replaced
                // (e.g. a fast disconnect/reconnect cycle) -- ignore it.
                guard self.connection === theConnection else { return }
                self.applyProtocolVersionResult(reported: reported)
            }
        }
    }

    /// Must only run on `stateQueue`. Split out from `verifyProtocolVersion`
    /// so `HelperClientTests` can exercise the comparison/state-transition
    /// logic in isolation, without any XPC round trip (Task 3.1 brief point
    /// 4).
    private func applyProtocolVersionResult(reported: Int) {
        let outcome = HelperClient.evaluateProtocolVersion(reported: reported)
        switch outcome {
        case .connected:
            Logging.xpc.info("protocolVersion OK (helper=\(reported, privacy: .public), app expects \(GogglesXPC.currentProtocolVersion, privacy: .public))")
            connectionState = .connected
        case .versionMismatch(let reported, let expected):
            // "Fails loudly" (task brief, exit criterion): `.fault` level,
            // not `.error`/`.info` -- this is a build-vs-build
            // incompatibility a developer/user should not be able to miss
            // in Console.app/`log show`, and there is no SwiftUI state
            // machine yet (Task 3.4's job) to surface it visually, so this
            // log line plus `connectionState` is the whole story for now.
            // `privacy: .public` throughout: default os_log privacy
            // redacts non-literal interpolations as `<private>`, which
            // would defeat "fails loudly" for exactly the two numbers that
            // matter here.
            Logging.xpc.fault("PROTOCOL VERSION MISMATCH: helper reports \(reported, privacy: .public), app expects \(expected, privacy: .public). Refusing to stream until this is resolved (reinstall/update the helper or the app).")
            connectionState = outcome
        default:
            break
        }
    }

    /// Pure, XPC-free comparison logic (Task 3.1 brief point 4: "This piece
    /// IS unit-testable even if the full XPC round trip isn't"). Exposed
    /// as `internal` (not `private`) specifically so
    /// `HelperClientTests.swift`, in the same module's test target, can
    /// call it directly with a fabricated mismatched value.
    static func evaluateProtocolVersion(
        reported: Int,
        expected: Int = GogglesXPC.currentProtocolVersion
    ) -> HelperClientConnectionState {
        reported == expected ? .connected : .versionMismatch(reported: reported, expected: expected)
    }

    // MARK: - Exported-object callback handling (may arrive off stateQueue;
    // each hops onto stateQueue itself where it touches shared state, then
    // onto the main queue for the public closures -- mirrors
    // `HelperService`'s PipelineDelegate methods' identical pattern)

    /// Multi-device picker design item 6: drops a callback whose
    /// `deviceId` doesn't match this client's `streamingDeviceId` -- see
    /// that property's doc comment for why this is a defensive check, not
    /// the primary scoping mechanism (the helper's own fan-out already is).
    private func isForCurrentDevice(_ deviceId: String) -> Bool {
        deviceId == streamingDeviceId
    }

    fileprivate func handleDeviceChanged(_ deviceId: String, _ info: DeviceInfo?) {
        guard isForCurrentDevice(deviceId) else { return }
        Logging.client.info("deviceChanged: \(info?.product ?? "nil", privacy: .public)")
        let handler = onDeviceChanged
        DispatchQueue.main.async { handler?(info) }
    }

    fileprivate func handleStateChanged(_ deviceId: String, _ state: Int, detail: String?) {
        guard isForCurrentDevice(deviceId) else { return }
        let name = GogglesState(rawValue: state).map { String(describing: $0) } ?? "unknown(\(state))"
        Logging.client.info("stateChanged: \(name, privacy: .public)\(detail.map { " [\($0)]" } ?? "", privacy: .public)")
        let handler = onHelperStateChanged
        DispatchQueue.main.async { handler?(state, detail) }
    }

    fileprivate func handleNALUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        guard isForCurrentDevice(deviceId) else { return }
        fpsCounter.recordFrame()
        let handler = onNALUnit
        DispatchQueue.main.async { handler?(data, nalType, isParameterSet, hostTime) }
    }

    fileprivate func handleStats(_ deviceId: String, _ stats: StreamStats) {
        guard isForCurrentDevice(deviceId) else { return }
        // Logged alongside (not instead of) the independent client-side
        // `NALFPSCounter` -- see that type's doc comment for why both
        // numbers matter. This is the helper's own self-reported fps.
        Logging.client.info("helper-reported stats: fps=\(stats.fps, privacy: .public) bitrate=\(stats.bitrateKbps, format: .fixed(precision: 1), privacy: .public)kbps drops=\(stats.drops, privacy: .public)")
        let handler = onStats
        DispatchQueue.main.async { handler?(stats) }
    }
}

/// The `GogglesClientProtocol` object actually handed to `NSXPCConnection`
/// as `exportedObject`. Kept as a small standalone `NSObject` (rather than
/// making `HelperClient` itself conform to `GogglesClientProtocol`)
/// specifically so it can hold only a **weak** reference back to
/// `HelperClient` -- the connection retains `exportedObject` strongly, and
/// `HelperClient` retains the connection strongly, so the reverse edge
/// must not also be strong or the pair leaks each other for the process's
/// entire lifetime.
private final class ExportedClient: NSObject, GogglesClientProtocol {
    weak var owner: HelperClient?

    func deviceChanged(_ deviceId: String, _ info: DeviceInfo?) {
        owner?.handleDeviceChanged(deviceId, info)
    }

    func stateChanged(_ deviceId: String, _ state: Int, detail: String?) {
        owner?.handleStateChanged(deviceId, state, detail: detail)
    }

    func nalUnit(_ deviceId: String, _ data: Data, nalType: UInt8, isParameterSet: Bool, hostTime: UInt64) {
        owner?.handleNALUnit(deviceId, data, nalType: nalType, isParameterSet: isParameterSet, hostTime: hostTime)
    }

    func stats(_ deviceId: String, _ stats: StreamStats) {
        owner?.handleStats(deviceId, stats)
    }
}
