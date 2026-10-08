import Foundation
import Combine

/// App events user-configured hooks can react to. Nothing runs unless the user set a script/webhook.
enum AppEvent: String, CaseIterable, Identifiable {
    case streamLive, streamLost, recordingStarted, recordingStopped, replaySaved, screenshotSaved, batteryLow
    var id: String { rawValue }
}

extension Notification.Name {
    /// userInfo: ["path": String] (optional). Posted by the views, mapped to EventBus by `EventHookInstaller`.
    static let gogglesRecordingStarted = Notification.Name("GogglesRecordingStarted")
    static let gogglesRecordingStopped = Notification.Name("GogglesRecordingStopped")
    static let gogglesReplaySaved = Notification.Name("GogglesReplaySaved")
    static let gogglesScreenshotSaved = Notification.Name("GogglesScreenshotSaved")
}

/// Pure helpers (unit-tested).
enum EventHookLogic {
    static func payloadJSON(event: AppEvent, fields: [String: Any], date: Date = Date()) -> String {
        var obj = fields.filter { JSONSerialization.isValidJSONObject([$0.value]) }
        obj["event"] = event.rawValue
        obj["timestamp"] = ISO8601DateFormatter().string(from: date)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"event\":\"\(event.rawValue)\"}" }
        return s
    }

    static func environment(base: [String: String], event: AppEvent, payload: String) -> [String: String] {
        var env = base
        env["GOGGLES_EVENT"] = event.rawValue
        env["GOGGLES_PAYLOAD"] = payload
        return env
    }

    /// True only when the battery goes from >= threshold to < threshold (not on first reading, not while staying low).
    static func batteryCrossedBelow(previous: Int?, current: Int?, threshold: Int) -> Bool {
        guard let previous, let current else { return false }
        return previous >= threshold && current < threshold
    }

    /// Stream events from kind transitions: entering .live -> live, leaving it (incl. stalled) -> lost.
    static func streamEvent(from old: GogglesUIStateKind?, to new: GogglesUIStateKind) -> AppEvent? {
        if new == .live && old != .live { return .streamLive }
        if old == .live && new != .live { return .streamLost }
        return nil
    }

    /// Only http(s) URLs with a host are accepted.
    static func validWebhook(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }
}

/// Turns raw live/not-live flips into stream events only after the new state held steady for
/// `stableFor` seconds, so a flapping signal does not run the hooks over and over. Pure: the
/// caller supplies the clock. A stream that was never announced live never produces "lost".
struct StreamEventDebouncer {
    static let defaultStableFor: TimeInterval = 3

    let stableFor: TimeInterval
    /// What the hooks were last told (false until the first announced live).
    private(set) var announcedLive = false
    private var pending: (live: Bool, since: Date)?

    init(stableFor: TimeInterval = StreamEventDebouncer.defaultStableFor) { self.stableFor = stableFor }

    /// The state kind changed (or was re-reported). Returns an event only via `tick`.
    mutating func observe(_ kind: GogglesUIStateKind, at now: Date) {
        let live = kind == .live
        if live == announcedLive { pending = nil; return }
        if pending?.live != live { pending = (live, now) }
    }

    /// Call periodically. Returns the event once the pending state has been stable long enough.
    mutating func tick(at now: Date) -> AppEvent? {
        guard let p = pending, now.timeIntervalSince(p.since) >= stableFor else { return nil }
        pending = nil
        announcedLive = p.live
        return p.live ? .streamLive : .streamLost
    }
}

enum EventHookConfig {
    static let batteryKey = "hookBatteryThreshold"
    static let defaultBattery = 15
    static func scriptKey(_ e: AppEvent) -> String { "hookScript.\(e.rawValue)" }
    static func webhookKey(_ e: AppEvent) -> String { "hookWebhook.\(e.rawValue)" }

    /// Marker (stored in the Keychain, which other processes can't write without a prompt) saying the
    /// script paths have been moved out of the plain-text defaults domain.
    static let migratedKey = "hookScriptsMigrated"
    private static let migrationOnce: Void = { migrateScriptPaths() }()

    /// The program to run for `e`. Script paths live in the Keychain: any process running as the same
    /// user can edit UserDefaults, so a path found there after migration is never trusted. (Builds whose
    /// Keychain refuses writes, i.e. unsigned dev builds, keep using the defaults fallback.)
    static func script(_ e: AppEvent) -> String {
        _ = migrationOnce
        if SecretStore.backend.read(migratedKey) != nil { return SecretStore.backend.read(scriptKey(e)) ?? "" }
        return SecretStore.get(scriptKey(e))
    }

    static func setScript(_ path: String, for e: AppEvent) { SecretStore.set(path, for: scriptKey(e)) }

    /// One-time move of existing plain-text script paths into the Keychain. Safe to call repeatedly.
    static func migrateScriptPaths() {
        guard SecretStore.backend.read(migratedKey) == nil else { return }
        var allMoved = true
        for e in AppEvent.allCases {
            let key = scriptKey(e)
            guard let v = SecretStore.defaults.string(forKey: key), !v.isEmpty else { continue }
            if SecretStore.backend.write(v, key) { SecretStore.defaults.removeObject(forKey: key) } else { allMoved = false }
        }
        if allMoved { _ = SecretStore.backend.write("1", migratedKey) }
    }
    static func webhook(_ e: AppEvent) -> String { SecretStore.get(webhookKey(e)) }
    static var batteryThreshold: Int {
        let v = UserDefaults.standard.object(forKey: batteryKey) as? Int
        return min(max(v ?? defaultBattery, 1), 99)
    }
}

struct HookRun: Identifiable {
    let id = UUID()
    let date: Date
    let event: AppEvent
    let target: String
    let exitCode: Int32?   // script exit code, or HTTP status for webhooks
    let output: String
}

/// Last 50 runs, in memory only.
final class HookLog: ObservableObject {
    static let shared = HookLog()
    @Published private(set) var runs: [HookRun] = []
    func add(_ run: HookRun) {
        DispatchQueue.main.async {
            self.runs.insert(run, at: 0)
            if self.runs.count > 50 { self.runs.removeLast(self.runs.count - 50) }
        }
    }
    func clear() { DispatchQueue.main.async { self.runs = [] } }
}

/// Central bus. Local code only; there is no remote trigger. Never blocks the caller.
final class EventBus {
    static let shared = EventBus()
    static let timeout: TimeInterval = 10
    private let queue = DispatchQueue(label: "eventbus", qos: .utility, attributes: .concurrent)

    func post(_ event: AppEvent, payload: [String: Any] = [:]) {
        let script = EventHookConfig.script(event)
        let hook = EventHookConfig.webhook(event)
        guard !script.isEmpty || !hook.isEmpty else { return }
        let json = EventHookLogic.payloadJSON(event: event, fields: payload)
        if !script.isEmpty { queue.async { Self.runScript(path: script, event: event, json: json) } }
        if !hook.isEmpty { queue.async { Self.postWebhook(urlString: hook, event: event, json: json) } }
    }

    private static func runScript(path: String, event: AppEvent, json: String) {
        let run = execute(path: path, event: event, json: json, timeout: timeout)
        HookLog.shared.add(run)
    }

    /// Runs the program in its own process group (no shell). On timeout the whole group is killed,
    /// so children the script started don't outlive it.
    static func execute(path: String, event: AppEvent, json: String, timeout: TimeInterval) -> HookRun {
        func failed(_ msg: String) -> HookRun {
            HookRun(date: Date(), event: event, target: path, exitCode: nil, output: msg)
        }
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return failed("not an executable file") }
        signal(SIGPIPE, SIG_IGN)  // script may exit without reading stdin

        var inFDs: [Int32] = [0, 0], outFDs: [Int32] = [0, 0]
        guard pipe(&inFDs) == 0 else { return failed("pipe failed") }
        guard pipe(&outFDs) == 0 else { close(inFDs[0]); close(inFDs[1]); return failed("pipe failed") }

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, inFDs[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&fa, outFDs[1], 2)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)  // new group led by the child
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }

        let env = EventHookLogic.environment(base: ProcessInfo.processInfo.environment, event: event, payload: json)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup(event.rawValue), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        close(inFDs[0]); close(outFDs[1])
        guard rc == 0 else {
            close(inFDs[1]); close(outFDs[0])
            return failed(String(cString: strerror(rc)))
        }

        // Capture up to 2 KiB of output; keep draining so the child never blocks on a full pipe.
        var captured = Data()
        let lock = NSLock()
        let reader = FileHandle(fileDescriptor: outFDs[0], closeOnDealloc: false)
        let drained = DispatchSemaphore(value: 0)
        let outFD = outFDs[0]
        DispatchQueue.global(qos: .utility).async {
            while true {
                let d = reader.availableData
                if d.isEmpty { break }
                lock.lock(); if captured.count < 2048 { captured.append(d.prefix(2048 - captured.count)) }; lock.unlock()
            }
            close(outFD) // the reader owns the descriptor
            drained.signal()
        }

        let writer = FileHandle(fileDescriptor: inFDs[1], closeOnDealloc: false)
        try? writer.write(contentsOf: Data(json.utf8))
        close(inFDs[1])

        var status: Int32 = 0
        func reap(until deadline: DispatchTime) -> Bool {
            while true {
                let r = waitpid(pid, &status, WNOHANG)
                if r == pid || (r == -1 && errno != EINTR) { return true }
                if DispatchTime.now() >= deadline { return false }
                usleep(20_000)
            }
        }
        var timedOut = false
        if !reap(until: .now() + timeout) {
            timedOut = true
            killpg(pid, SIGTERM)
            if !reap(until: .now() + 2) {
                killpg(pid, SIGKILL)
                _ = reap(until: .now() + 5)
            }
            killpg(pid, SIGKILL) // stragglers that ignored SIGTERM
        }
        // The pipe closes once every process in the group is gone; don't hang if a stray holder remains.
        _ = drained.wait(timeout: .now() + 1)
        lock.lock(); let text = String(decoding: captured, as: UTF8.self); lock.unlock()
        let exit: Int32? = timedOut ? nil : (status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
        return HookRun(date: Date(), event: event, target: path, exitCode: exit,
                       output: timedOut ? "timed out after \(Int(timeout))s, process group terminated" : text)
    }

    private static func postWebhook(urlString: String, event: AppEvent, json: String) {
        guard let url = EventHookLogic.validWebhook(urlString) else {
            HookLog.shared.add(HookRun(date: Date(), event: event, target: urlString, exitCode: nil, output: "invalid URL (http/https only)"))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(event.rawValue, forHTTPHeaderField: "X-Goggles-Event")
        req.httpBody = Data(json.utf8)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse).map { Int32($0.statusCode) }
            let body = data.map { String(decoding: $0.prefix(2048), as: UTF8.self) } ?? ""
            HookLog.shared.add(HookRun(date: Date(), event: event, target: urlString, exitCode: code,
                                       output: err?.localizedDescription ?? body))
        }.resume()
    }
}

/// Bridges app state/notifications onto the bus. Multi-window: one set of
/// state/battery observers per open goggles window (keyed by deviceId, which
/// is added to those events' payloads); the recording/replay/screenshot
/// notification bridge is app-wide and installed once.
private final class StreamDebouncerBox { var value = StreamEventDebouncer() }

enum EventHookInstaller {
    private static var perDevice: [String: Set<AnyCancellable>] = [:]
    private static var notificationBag = Set<AnyCancellable>()

    static func uninstall(deviceId: String) {
        perDevice[deviceId] = nil
    }

    static func install(coordinator: GogglesConnectionCoordinator) {
        let deviceId = coordinator.deviceId
        var bag = Set<AnyCancellable>()
        // Debounced: a flapping signal must not fire streamLost/streamLive hooks on every flip.
        let debouncer = StreamDebouncerBox()
        coordinator.$uiState.sink { state in
            debouncer.value.observe(state.kind, at: Date())
        }.store(in: &bag)
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { _ in
            if let e = debouncer.value.tick(at: Date()) {
                EventBus.shared.post(e, payload: ["deviceId": deviceId])
                NotificationCenter.default.post(name: .gogglesHookEventFired, object: nil,
                                                userInfo: ["event": e, "deviceId": deviceId])
            }
        }.store(in: &bag)

        var lastBattery: Int?
        coordinator.$batteryPercent.sink { pct in
            let threshold = EventHookConfig.batteryThreshold
            if EventHookLogic.batteryCrossedBelow(previous: lastBattery, current: pct, threshold: threshold), let pct {
                EventBus.shared.post(.batteryLow, payload: ["percent": pct, "threshold": threshold, "deviceId": deviceId])
                NotificationCenter.default.post(name: .gogglesHookEventFired, object: nil,
                                                userInfo: ["event": AppEvent.batteryLow, "deviceId": deviceId, "percent": pct])
            }
            if pct != nil { lastBattery = pct }
        }.store(in: &bag)
        perDevice[deviceId] = bag

        guard notificationBag.isEmpty else { return }
        let map: [(Notification.Name, AppEvent)] = [
            (.gogglesRecordingStarted, .recordingStarted), (.gogglesRecordingStopped, .recordingStopped),
            (.gogglesReplaySaved, .replaySaved), (.gogglesScreenshotSaved, .screenshotSaved),
        ]
        for (name, event) in map {
            NotificationCenter.default.publisher(for: name).sink { n in
                EventBus.shared.post(event, payload: (n.userInfo as? [String: Any]) ?? [:])
            }.store(in: &notificationBag)
        }
    }
}
