import Foundation
import Combine

// Sends alert messages to a self-hosted ntfy server and pings an optional dead-man heartbeat URL.
// Off the main thread, never blocks, bounded retries. The token is read from SecretStore only when a
// message is actually sent. Logs carry the host and a status, never the topic, token or message text.

enum NtfyRequest {
    /// ntfy topics: letters, digits, `_` and `-`, at most 64.
    static func validTopic(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(t.count), t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return t
    }

    /// `<server>/<topic>`; the server must be http(s) with a host (same rule as the event webhooks).
    static func url(server: String, topic: String) -> URL? {
        guard var base = EventHookLogic.validWebhook(server)?.absoluteString, let t = validTopic(topic) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + t)
    }

    /// HTTP header values must be plain ASCII on one line: fold accents, drop the rest.
    static func headerSafe(_ s: String) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: nil)
        return String(folded.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
    }

    static let timeout: TimeInterval = 8

    static func make(server: String, topic: String, message m: AlertMessage, token: String) -> URLRequest? {
        guard let url = url(server: server, topic: topic) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue(headerSafe(m.title), forHTTPHeaderField: "Title")
        r.setValue(String(min(max(m.priority, 1), 5)), forHTTPHeaderField: "Priority")
        r.setValue(headerSafe(m.tags), forHTTPHeaderField: "Tags")
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tok.isEmpty { r.setValue("Bearer " + headerSafe(tok), forHTTPHeaderField: "Authorization") }
        r.httpBody = Data(m.body.utf8)
        return r
    }

    static func heartbeat(_ s: String) -> URLRequest? {
        guard let u = EventHookLogic.validWebhook(s) else { return nil }
        return URLRequest(url: u, timeoutInterval: timeout)
    }
}

/// Status code of the response, nil when the request itself failed.
typealias AlertTransport = @Sendable (URLRequest) async -> Int?

enum AlertURLSession {
    static let transport: AlertTransport = { req in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = NtfyRequest.timeout
        cfg.timeoutIntervalForResource = NtfyRequest.timeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, resp) = try? await session.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}

final class NtfySender: @unchecked Sendable {
    private let transport: AlertTransport
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let token: @Sendable () -> String
    let backoff: [TimeInterval]

    /// One try plus `backoff.count` retries (3 by default: 1 s, 2 s, 4 s).
    init(transport: @escaping AlertTransport = AlertURLSession.transport,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
         token: @escaping @Sendable () -> String = { SecretStore.get(AlertPrefs.tokenKey) },
         backoff: [TimeInterval] = [1, 2, 4]) {
        self.transport = transport; self.sleep = sleep; self.token = token; self.backoff = backoff
    }

    /// Retry on network errors, 429 and 5xx; any other answer is final.
    func deliver(_ req: URLRequest) async -> Bool {
        for attempt in 0...backoff.count {
            let code = await transport(req)
            if let code, (200..<300).contains(code) { return true }
            if let code, code != 429, code < 500 { return false }
            if attempt < backoff.count { await sleep(backoff[attempt]) }
        }
        return false
    }

    /// Fire and forget; `done` runs on a background thread.
    func send(_ m: AlertMessage, server: String, topic: String, done: @escaping @Sendable (Bool) -> Void) {
        Task.detached(priority: .utility) { [self] in
            guard let req = NtfyRequest.make(server: server, topic: topic, message: m, token: token()) else { done(false); return }
            done(await deliver(req))
        }
    }

    func ping(_ urlString: String, done: @escaping @Sendable (Bool) -> Void) {
        Task.detached(priority: .utility) { [self] in
            guard let req = NtfyRequest.heartbeat(urlString) else { done(false); return }
            let code = await transport(req)
            done(code.map { (200..<300).contains($0) } ?? false)
        }
    }
}

/// Dead-man ping schedule: due every `interval` seconds, only while Away mode is on.
struct HeartbeatSchedule {
    static let interval: TimeInterval = 30
    private var last: Date?
    mutating func due(away: Bool, urlValid: Bool, now: Date) -> Bool {
        guard away, urlValid else { last = nil; return false }
        if let l = last, now.timeIntervalSince(l) < Self.interval { return false }
        last = now
        return true
    }
}

/// Main-thread glue: EventStatus calls `update` once a second. Does nothing at all (no Keychain, no
/// network) until Away mode is on and the server and topic are valid.
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    struct Status: Equatable { let ok: Bool; let at: Date }
    @Published private(set) var lastSend: Status?
    @Published private(set) var lastPing: Status?

    private var engine = AlertEngine()
    private var inputs = AlertInputs()
    private var heartbeat = HeartbeatSchedule()
    private let sender: NtfySender
    private let defaults: UserDefaults
    private let now: () -> Date

    init(sender: NtfySender = NtfySender(), defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.sender = sender; self.defaults = defaults; self.now = now
    }

    private var server: String { defaults.string(forKey: AlertPrefs.serverKey) ?? "" }
    private var topic: String { defaults.string(forKey: AlertPrefs.topicKey) ?? "" }
    private var configured: Bool { NtfyRequest.url(server: server, topic: topic) != nil }

    func update(feeds: [AlertFeed], helperDown: Bool, missingPrograms: [String]) {
        let config = AlertPrefs.config(defaults)
        guard config.away, configured else { engine.reset(); inputs = AlertInputs(); _ = heartbeat.due(away: false, urlValid: false, now: now()); return }
        let t = now()
        let r = inputs.conditions(feeds: feeds, helperDown: helperDown, missingPrograms: missingPrograms, now: t)
        for id in r.gone { engine.forget(feedID: id) }
        for m in engine.update(r.conditions, config: config, now: t) { deliver(m) }
        let hb = defaults.string(forKey: AlertPrefs.heartbeatKey) ?? ""
        if heartbeat.due(away: true, urlValid: EventHookLogic.validWebhook(hb) != nil, now: t) {
            sender.ping(hb) { [weak self] ok in DispatchQueue.main.async { self?.lastPing = Status(ok: ok, at: Date()) } }
        }
    }

    /// Settings "Send test": one default-priority and one urgent message, regardless of Away mode.
    func sendTests() {
        deliver(AlertMessage(title: "GogglesView: " + L("Test"), body: L("Test alert from GogglesView"), priority: 3, tags: "white_check_mark", isRecovery: false))
        deliver(AlertMessage(title: "GogglesView: " + L("Test (urgent)"), body: L("Urgent test alert from GogglesView"), priority: 5, tags: "rotating_light", isRecovery: false))
    }

    private func deliver(_ m: AlertMessage) {
        let host = URL(string: server)?.host ?? "?"
        sender.send(m, server: server, topic: topic) { [weak self] ok in
            if !ok { Logging.alerts.error("ntfy send failed (host \(host, privacy: .public), priority \(m.priority))") }
            DispatchQueue.main.async { self?.lastSend = Status(ok: ok, at: Date()) }
        }
    }
}
