import Foundation
import Combine

/// Preferences for the opt-in OBS Studio integration. The WebSocket password lives in the Keychain
/// (via `SecretStore`), never in UserDefaults.
enum OBSPrefs {
    static let enabledKey = "obsEnabled"
    static let hostKey = "obsHost"
    static let portKey = "obsPort"
    static let passwordKey = "obsPassword"
    static let recordWithStreamKey = "obsRecordWithStream"
    static let graceSecondsKey = "obsGraceSeconds"
    static let sceneSwitchKey = "obsSceneSwitch"
    static let liveSceneKey = "obsLiveScene"
    static let lostSceneKey = "obsLostScene"
    static let stopWithMineKey = "obsStopWithMine"

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 4455
    static let defaultGraceSeconds = 30
    static let graceRange = 5...600

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var host: String {
        let h = UserDefaults.standard.string(forKey: hostKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return h.isEmpty ? defaultHost : h
    }
    static var port: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(p) ? p : defaultPort
    }
    static var password: String { SecretStore.get(passwordKey) }

    static var rules: OBSRules {
        let d = UserDefaults.standard
        let grace = d.object(forKey: graceSecondsKey) as? Int ?? defaultGraceSeconds
        return OBSRules(
            recordWithStream: d.bool(forKey: recordWithStreamKey),
            graceSeconds: TimeInterval(min(max(grace, graceRange.lowerBound), graceRange.upperBound)),
            switchScenes: d.bool(forKey: sceneSwitchKey),
            liveScene: d.string(forKey: liveSceneKey) ?? "",
            lostScene: d.string(forKey: lostSceneKey) ?? "",
            stopWithMyRecording: d.bool(forKey: stopWithMineKey))
    }
}

/// What the user switched on. Every rule is off by default.
struct OBSRules: Equatable {
    /// (a) start OBS recording when the goggles go live, stop it after the signal stays lost for `graceSeconds`.
    var recordWithStream = false
    var graceSeconds: TimeInterval = TimeInterval(OBSPrefs.defaultGraceSeconds)
    /// (b) switch to `liveScene` when live and `lostScene` when lost (an empty name means "leave it").
    var switchScenes = false
    var liveScene = ""
    var lostScene = ""
    /// (c) stop the OBS recording GogglesView started when the user stops their own recording.
    var stopWithMyRecording = false
}

enum OBSAction: Equatable {
    case startRecord
    case stopRecord
    case setScene(String)
}

/// Pure rule engine. The caller feeds debounced stream events (see `StreamEventDebouncer`) and a
/// clock; the engine says which OBS actions to run. It only reacts to GogglesView transitions and
/// only stops a recording it started itself, so it never fights what the user does in OBS.
struct OBSRuleEngine {
    enum Input: Equatable {
        case streamLive
        case streamLost
        /// The goggles session went away (unplugged or window closed).
        case sessionDisconnected
        /// The user stopped GogglesView's own recording.
        case userRecordingStopped
        /// Time passing; checks the grace period.
        case tick
    }

    /// True while a recording that this engine asked OBS to start may still be running.
    private(set) var ownsRecording = false
    private var lostSince: Date?

    init() {}

    var isWaitingOutGrace: Bool { lostSince != nil }

    mutating func handle(_ input: Input, rules: OBSRules, at now: Date) -> [OBSAction] {
        var out: [OBSAction] = []
        switch input {
        case .streamLive:
            lostSince = nil
            if rules.switchScenes, !rules.liveScene.isEmpty { out.append(.setScene(rules.liveScene)) }
            if rules.recordWithStream, !ownsRecording {
                ownsRecording = true
                out.append(.startRecord)
            }
        case .streamLost:
            if rules.switchScenes, !rules.lostScene.isEmpty { out.append(.setScene(rules.lostScene)) }
            if rules.recordWithStream, ownsRecording, lostSince == nil { lostSince = now }
        case .sessionDisconnected:
            lostSince = nil
            if ownsRecording {
                ownsRecording = false
                if rules.recordWithStream { out.append(.stopRecord) }
            }
        case .userRecordingStopped:
            lostSince = nil
            if ownsRecording {
                ownsRecording = false
                if rules.stopWithMyRecording { out.append(.stopRecord) }
            }
        case .tick:
            if let since = lostSince {
                if !rules.recordWithStream {
                    lostSince = nil
                } else if now.timeIntervalSince(since) >= rules.graceSeconds {
                    lostSince = nil
                    ownsRecording = false
                    out.append(.stopRecord)
                }
            }
        }
        return out
    }

    /// The recording was not started by us (OBS was already recording, or the start failed).
    mutating func recordingNotOwned() { ownsRecording = false; lostSince = nil }
}

/// Tracks which goggles windows are live so several windows map to one "live / lost" state.
struct OBSLiveTracker {
    private(set) var liveDevices: Set<String> = []

    /// Returns the combined transition, if any.
    mutating func update(deviceId: String, live: Bool) -> OBSRuleEngine.Input? {
        let wasLive = !liveDevices.isEmpty
        if live { liveDevices.insert(deviceId) } else { liveDevices.remove(deviceId) }
        let isLive = !liveDevices.isEmpty
        if isLive && !wasLive { return .streamLive }
        if !isLive && wasLive { return .streamLost }
        return nil
    }
}

/// Runs the OBS rules inside the app: owns the client, keeps it connected while enabled, and
/// executes the engine's actions. Opt-in; with `obsEnabled` off nothing connects.
@MainActor
final class OBSIntegration: ObservableObject {
    static let shared = OBSIntegration()

    @Published private(set) var status = L("Not connected")
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var scenes: [String] = []

    private let client = OBSClient()
    private var engine = OBSRuleEngine()
    private var tracker = OBSLiveTracker()
    private var loop: Task<Void, Never>?
    private var ticker: AnyCancellable?
    private var observer: AnyCancellable?

    /// Idempotent. Call at launch and whenever a pref changes.
    func settingsChanged() {
        loop?.cancel(); loop = nil
        ticker = nil
        guard OBSPrefs.enabled else {
            Task { await client.disconnect() }
            isConnected = false; status = L("Not connected"); lastError = nil; scenes = []
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.publisher(for: .gogglesRecordingStopped).sink { [weak self] _ in
                Task { @MainActor in self?.feed(.userRecordingStopped) }
            }
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.feed(.tick)
        }
        loop = Task { [weak self] in await self?.connectionLoop() }
    }

    func startIfEnabled() {
        guard loop == nil, OBSPrefs.enabled else { return }
        settingsChanged()
    }

    /// Stream state from one goggles window (already debounced).
    func streamEvent(_ event: AppEvent, deviceId: String) {
        guard OBSPrefs.enabled else { return }
        guard event == .streamLive || event == .streamLost,
              let input = tracker.update(deviceId: deviceId, live: event == .streamLive) else { return }
        feed(input)
    }

    /// A goggles window went away.
    func deviceGone(_ deviceId: String) {
        guard OBSPrefs.enabled else { return }
        if let input = tracker.update(deviceId: deviceId, live: false) { feed(input) }
        feed(.sessionDisconnected)
    }

    private func feed(_ input: OBSRuleEngine.Input) {
        guard OBSPrefs.enabled else { return }
        let actions = engine.handle(input, rules: OBSPrefs.rules, at: Date())
        guard !actions.isEmpty else { return }
        Task { await run(actions) }
    }

    private func run(_ actions: [OBSAction]) async {
        for action in actions {
            do {
                switch action {
                case .setScene(let name): try await client.setCurrentProgramScene(name)
                case .stopRecord: try await client.stopRecord()
                case .startRecord:
                    if try await client.getRecordStatus() {
                        engine.recordingNotOwned()  // the user is already recording in OBS: leave it alone
                    } else {
                        try await client.startRecord()
                    }
                }
            } catch {
                if action == .startRecord { engine.recordingNotOwned() }
                lastError = error.localizedDescription  // one visible line, no retries
            }
        }
    }

    private func connectionLoop() async {
        var attempt = 0
        while !Task.isCancelled && OBSPrefs.enabled {
            do {
                try await client.connect(host: OBSPrefs.host, port: OBSPrefs.port, password: OBSPrefs.password)
                attempt = 0
                lastError = nil
                let v = try? await client.getVersion()
                isConnected = true
                status = L("Connected to OBS %@", v?.obsVersion ?? "").trimmingCharacters(in: .whitespaces)
                await refreshScenes()
                await client.waitUntilClosed()
                isConnected = false
                status = L("Not connected")
            } catch {
                isConnected = false
                status = L("Not connected")
                lastError = error.localizedDescription
                if let e = error as? OBSError, e == .wrongPassword || e == .passwordRequired { return }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(ReconnectBackoff.delay(attempt: attempt) * 1_000_000_000))
            attempt += 1
        }
    }

    func refreshScenes() async {
        if let s = try? await client.getSceneList() { scenes = s }
    }

    /// One-off check with a throwaway connection: the OBS version or a readable error.
    nonisolated static func testConnection(host: String, port: Int, password: String) async -> Result<OBSVersion, OBSError> {
        let c = OBSClient()
        do {
            try await c.connect(host: host, port: port, password: password)
            let v = try await c.getVersion()
            await c.disconnect()
            return .success(v)
        } catch let e as OBSError {
            await c.disconnect()
            return .failure(e)
        } catch {
            await c.disconnect()
            return .failure(.unreachable)
        }
    }
}
