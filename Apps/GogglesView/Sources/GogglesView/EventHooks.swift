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

enum EventHookConfig {
    static let batteryKey = "hookBatteryThreshold"
    static let defaultBattery = 15
    static func scriptKey(_ e: AppEvent) -> String { "hookScript.\(e.rawValue)" }
    static func webhookKey(_ e: AppEvent) -> String { "hookWebhook.\(e.rawValue)" }
    static func script(_ e: AppEvent) -> String { UserDefaults.standard.string(forKey: scriptKey(e)) ?? "" }
    static func webhook(_ e: AppEvent) -> String { UserDefaults.standard.string(forKey: webhookKey(e)) ?? "" }
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
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            HookLog.shared.add(HookRun(date: Date(), event: event, target: path, exitCode: nil, output: "not an executable file"))
            return
        }
        signal(SIGPIPE, SIG_IGN)  // script may exit without reading stdin
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)  // no shell
        p.arguments = [event.rawValue]
        p.environment = EventHookLogic.environment(base: ProcessInfo.processInfo.environment, event: event, payload: json)
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = out
        var captured = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); if captured.count < 2048 { captured.append(d.prefix(2048 - captured.count)) }; lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            HookLog.shared.add(HookRun(date: Date(), event: event, target: path, exitCode: nil, output: error.localizedDescription))
            return
        }
        try? stdin.fileHandleForWriting.write(contentsOf: Data(json.utf8))
        try? stdin.fileHandleForWriting.close()
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); done.wait() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let text = String(decoding: captured, as: UTF8.self); lock.unlock()
        HookLog.shared.add(HookRun(date: Date(), event: event, target: path,
                                   exitCode: timedOut ? nil : p.terminationStatus,
                                   output: timedOut ? "timed out after \(Int(timeout))s, terminated" : text))
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
enum EventHookInstaller {
    private static var perDevice: [String: Set<AnyCancellable>] = [:]
    private static var notificationBag = Set<AnyCancellable>()

    static func uninstall(deviceId: String) {
        perDevice[deviceId] = nil
    }

    static func install(coordinator: GogglesConnectionCoordinator) {
        let deviceId = coordinator.deviceId
        var bag = Set<AnyCancellable>()
        var lastKind: GogglesUIStateKind?
        coordinator.$uiState.sink { state in
            let k = state.kind
            if let e = EventHookLogic.streamEvent(from: lastKind, to: k) { EventBus.shared.post(e, payload: ["deviceId": deviceId]) }
            lastKind = k
        }.store(in: &bag)

        var lastBattery: Int?
        coordinator.$batteryPercent.sink { pct in
            let threshold = EventHookConfig.batteryThreshold
            if EventHookLogic.batteryCrossedBelow(previous: lastBattery, current: pct, threshold: threshold), let pct {
                EventBus.shared.post(.batteryLow, payload: ["percent": pct, "threshold": threshold, "deviceId": deviceId])
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
