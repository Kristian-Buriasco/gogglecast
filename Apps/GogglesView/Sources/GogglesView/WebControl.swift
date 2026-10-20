import Foundation
import CoreImage
import CoreVideo

// Browser control center: the pure parts (prefs, actions, auth, rate limit, log, thumbnails, request
// handling). The app glue (real command sink, state feeder) is in WebControlApp.swift; the HTML page is
// in WebControlPage.swift. Plain HTTP on the LAN like the viewer: it shares the viewer's bind rules.

enum ControlPrefs {
    static let enabledKey = "webControlEnabled"
    static let tokenKey = "webControlToken"
    static let cookieName = "gv_control"
    /// Off unless the user turned it on in Settings.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Read lazily (SecretStore caches it); never touched at launch.
    static var token: String { SecretStore.get(tokenKey) }

    static func link(host: String, port: Int, token: String) -> String {
        "http://\(host):\(port)/control?c=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
}

enum ControlAction: String, CaseIterable {
    case recordStart = "record.start", recordStop = "record.stop", replaySave = "replay.save"
    case markerAdd = "marker.add", screenshot = "screenshot", reconnect = "reconnect"
    case outputsShow = "outputs.show", outputsHide = "outputs.hide"
    case awayOn = "away.on", awayOff = "away.off", previewOn = "preview.on", previewOff = "preview.off"
    case alertsTest = "alerts.test"

    /// Needs `confirm: true` (the page asks for a second tap).
    var destructive: Bool { [.recordStop, .outputsHide, .reconnect, .awayOff].contains(self) }
    var needsFeed: Bool { [.recordStart, .recordStop, .replaySave, .markerAdd, .screenshot, .reconnect].contains(self) }
}

struct ControlResult: Equatable {
    let ok: Bool
    let message: String
}

/// Executes an action. The real one hops to the main thread; tests use a fake. `completion` may be
/// called from any thread.
protocol ControlSink: AnyObject {
    func perform(_ action: ControlAction, feed: Int?, completion: @escaping (ControlResult) -> Void)
}

// MARK: Log

struct ControlLogEntry: Equatable {
    enum Kind: String { case action, alert, signal }
    let time: Date
    let kind: Kind
    let who: String   // remote address, or "system"
    let text: String
    let ok: Bool
}

/// Bounded in-memory ring (newest last). Observable so the Settings table refreshes.
final class ControlLog: ObservableObject {
    static let shared = ControlLog()
    let capacity: Int
    private let lock = NSLock()
    private var items: [ControlLogEntry] = []

    init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    func add(_ kind: ControlLogEntry.Kind, who: String, text: String, ok: Bool = true, at: Date = Date()) {
        lock.lock()
        items.append(ControlLogEntry(time: at, kind: kind, who: who, text: text, ok: ok))
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    /// Newest first.
    func recent(_ n: Int, kind: ControlLogEntry.Kind? = nil) -> [ControlLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.reversed().lazy.filter { kind == nil || $0.kind == kind }.prefix(n))
    }
}

// MARK: Rate limit

/// Sliding one-second windows: `perIP` actions per address and `global` over all addresses.
struct ControlRateLimiter {
    var perIP = 5
    var global = 10
    var window: TimeInterval = 1
    private var ipHits: [String: [Date]] = [:]
    private var allHits: [Date] = []

    mutating func allowIP(_ ip: String, now: Date) -> Bool {
        if ipHits.count > 256 { ipHits = ipHits.filter { $0.value.contains { now.timeIntervalSince($0) < window } } }
        var h = (ipHits[ip] ?? []).filter { now.timeIntervalSince($0) < window }
        guard h.count < perIP else { ipHits[ip] = h; return false }
        h.append(now); ipHits[ip] = h
        return true
    }

    mutating func allowGlobal(now: Date) -> Bool {
        allHits.removeAll { now.timeIntervalSince($0) >= window }
        guard allHits.count < global else { return false }
        allHits.append(now)
        return true
    }
}

// MARK: Thumbnails

/// Small JPEGs of the latest decoded frame. Everything runs on one background queue, so the decode path
/// is never touched beyond reading `latestDecodedFrame()` under its own lock. A feed is re-encoded at
/// most once per `minInterval`; nothing is encoded unless a client asks, so no polling means no work.
final class ThumbnailCache {
    static let minInterval: TimeInterval = 1
    static let width: CGFloat = 320
    private static let context = CIContext()

    /// Called on the cache's queue.
    var frameProvider: (Int) -> CVPixelBuffer? = { _ in nil }
    private let queue = DispatchQueue(label: "WebControl.thumbs", qos: .utility)
    private var cache: [Int: (data: Data, at: Date)] = [:]
    private(set) var encodeCount = 0

    func jpeg(feed: Int, now: Date = Date(), completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            if let c = cache[feed], now.timeIntervalSince(c.at) < Self.minInterval { return completion(c.data) }
            guard let buf = frameProvider(feed), let data = Self.encode(buf) else { cache[feed] = nil; return completion(nil) }
            encodeCount += 1
            cache[feed] = (data, now)
            completion(data)
        }
    }

    static func encode(_ buffer: CVPixelBuffer) -> Data? {
        let img = CIImage(cvPixelBuffer: buffer)
        guard img.extent.width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let s = min(1, width / img.extent.width)
        return context.jpegRepresentation(of: img.transformed(by: CGAffineTransform(scaleX: s, y: s)), colorSpace: space,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5])
    }
}

// MARK: State snapshot

enum ControlStateStore {
    private static let lock = NSLock()
    private static var snapshot = Data("{}".utf8)
    static var latest: Data { lock.lock(); defer { lock.unlock() }; return snapshot }
    static func set(_ d: Data) { lock.lock(); snapshot = d; lock.unlock() }
}

/// Richer than /status.json, still without device ids or serial numbers: feeds are addressed by index.
enum ControlState {
    struct Globals {
        var away = false
        var awayConfigured = false
        var hdmiShown = false
        var previewAvailable = false
        var controlEnabled = false
        var uptime: TimeInterval = 0
        /// Outputs not tied to one feed (RTMP, recording, HDMI windows).
        var extraOutputs: [OutputChip] = []
    }

    /// One chip per name; the worst state wins (error, then waiting, then on).
    static func merge(_ chips: [OutputChip]) -> [OutputChip] {
        func rank(_ s: OutputChip.State) -> Int { switch s { case .error: return 3; case .waiting: return 2; case .on: return 1; case .off: return 0 } }
        var order: [String] = [], best: [String: OutputChip.State] = [:]
        for c in chips {
            if best[c.name] == nil { order.append(c.name) }
            if rank(c.state) > rank(best[c.name] ?? .off) || best[c.name] == nil { best[c.name] = c.state }
        }
        return order.map { OutputChip(name: $0, state: best[$0] ?? .off) }
    }

    static func data(rows: [OverviewRow], names: [String], globals g: Globals, log: [ControlLogEntry], now: Date) -> Data {
        func health(_ h: FeedHealth) -> String { h == .good ? "good" : (h == .warning ? "warning" : "bad") }
        let feeds: [[String: Any]] = rows.enumerated().map { i, r in
            var f: [String: Any] = [
                "index": i, "name": i < names.count ? names[i] : "Feed \(i + 1)", "status": r.status, "live": r.isLive,
                "health": health(r.health), "issues": r.issues.map(\.code), "issueText": r.issues.map(\.text),
                "recording": r.isRecording, "elapsed": Int(r.elapsed),
                "outputs": r.outputs.map { ["name": $0.name, "state": "\($0.state)"] },
            ]
            if let v = r.fps { f["fps"] = v }
            if let v = r.battery { f["battery"] = v }
            if let v = r.drops { f["dropped"] = v }
            if let v = r.bitrateKbps { f["kbps"] = v }
            return f
        }
        let outputs = merge(rows.flatMap(\.outputs) + g.extraOutputs)
        let obj: [String: Any] = [
            "now": Int(now.timeIntervalSince1970 * 1000), "uptime": Int(g.uptime),
            "health": rows.map(\.health).max().map(health) ?? "none",
            "away": g.away, "awayConfigured": g.awayConfigured, "hdmiShown": g.hdmiShown, "previewAvailable": g.previewAvailable,
            "controlEnabled": g.controlEnabled,
            "feeds": feeds,
            "outputs": outputs.map { ["name": $0.name, "state": "\($0.state)"] },
            "log": log.map { ["t": Int($0.time.timeIntervalSince1970 * 1000), "kind": $0.kind.rawValue, "who": $0.who, "text": $0.text, "ok": $0.ok] },
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: Request handling

struct HTTPReply {
    var code: Int
    var type: String
    var body: Data
    var headers: [String: String] = [:]

    var reason: String {
        switch code {
        case 200: return "OK"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        default: return "Error"
        }
    }

    static func text(_ code: Int, _ s: String) -> HTTPReply { HTTPReply(code: code, type: "text/plain", body: Data(s.utf8)) }
    static func json(_ code: Int, _ obj: [String: Any]) -> HTTPReply {
        HTTPReply(code: code, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
}

final class ControlService {
    static let maxBody = 1024
    static let shared: ControlService = {
        let s = ControlService(sink: AppControlSink())
        s.thumbs.frameProvider = AppControlSink.frame
        return s
    }()

    let sink: ControlSink
    let log: ControlLog
    let thumbs: ThumbnailCache
    var isEnabled: () -> Bool = { ControlPrefs.enabled }
    var controlToken: () -> String = { ControlPrefs.token }
    var state: () -> Data = { ControlStateStore.latest }
    private let lock = NSLock()
    private var limiter = ControlRateLimiter()

    init(sink: ControlSink, log: ControlLog = .shared, thumbs: ThumbnailCache = ThumbnailCache()) {
        self.sink = sink; self.log = log; self.thumbs = thumbs
    }

    static func owns(_ path: String) -> Bool {
        path == "/control" || path == "/control.webmanifest" || path.hasPrefix("/control-icon-") || path.hasPrefix("/api/")
    }

    /// No early exit; an empty expected token never matches (unlike the viewer, control has no open mode).
    static func tokenOK(_ provided: String?, _ expected: String) -> Bool {
        !expected.isEmpty && WebRequest.tokenMatches(provided: provided ?? "", expected: expected)
    }

    static func cookie(_ header: String?, name: String) -> String? {
        for part in (header ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    /// Same-origin check for POST: the Origin (when sent) must be http and name exactly the Host we were asked for.
    static func originOK(origin: String?, host: String?) -> Bool {
        guard let origin else { return true } // non-browser client; the custom header and token still apply
        guard let host, let c = URLComponents(string: origin), c.scheme == "http", let h = c.host else { return false }
        return (h + (c.port.map { ":\($0)" } ?? "")).lowercased() == host.lowercased()
    }

    private func credential(_ req: WebRequest) -> String? {
        Self.cookie(req.headers["cookie"], name: ControlPrefs.cookieName) ?? req.headers["x-gv-token"]
    }

    /// Calls `reply` exactly once (possibly from another queue). Returns without blocking.
    func handle(_ req: WebRequest, remote: String, viewerToken: String, now: Date = Date(), reply: @escaping (HTTPReply) -> Void) {
        let enabled = isEnabled()
        switch req.path {
        case "/control.webmanifest", "/control-icon-180.png", "/control-icon-512.png":
            guard req.method == "GET" else { return reply(.text(405, "GET only")) }
            guard enabled else { return reply(.text(403, "Browser control is off")) }
            if req.path == "/control.webmanifest" {
                return reply(HTTPReply(code: 200, type: "application/manifest+json", body: Data(WebControlPage.manifest.utf8)))
            }
            guard let png = WebViewerIcon.png(size: req.path.contains("180") ? 180 : 512) else { return reply(.text(404, "Not found")) }
            reply(HTTPReply(code: 200, type: "image/png", body: png))

        case "/control":
            guard req.method == "GET" else { return reply(.text(405, "GET only")) }
            guard enabled else { return reply(.text(403, "Browser control is off. Turn on Allow control from the browser in GogglesView Settings > Outputs.")) }
            let token = controlToken()
            if let c = req.query["c"] {
                guard Self.tokenOK(c, token) else { return reply(WebControlPage.login(code: 401)) }
                // Move the token into a cookie and drop it from the address bar.
                return reply(HTTPReply(code: 302, type: "text/plain", body: Data(), headers: [
                    "Location": "/control",
                    "Set-Cookie": "\(ControlPrefs.cookieName)=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict",
                ]))
            }
            guard Self.tokenOK(credential(req), token) else { return reply(WebControlPage.login(code: 401)) }
            reply(HTTPReply(code: 200, type: "text/html; charset=utf-8", body: Data(WebControlPage.html.utf8)))

        case "/api/state":
            guard req.method == "GET" else { return reply(.text(405, "GET only")) }
            guard authorizedRead(req, viewerToken: viewerToken, enabled: enabled) else { return reply(.text(401, "Missing or wrong token")) }
            reply(HTTPReply(code: 200, type: "application/json", body: state()))

        case "/api/action":
            guard req.method == "POST" else { return reply(.text(405, "POST only")) }
            action(req, remote: remote, enabled: enabled, now: now, reply: reply)

        default:
            guard req.path.hasPrefix("/api/thumb/"), req.path.hasSuffix(".jpg") else { return reply(.text(404, "Not found")) }
            guard req.method == "GET" else { return reply(.text(405, "GET only")) }
            guard authorizedRead(req, viewerToken: viewerToken, enabled: enabled) else { return reply(.text(401, "Missing or wrong token")) }
            let n = req.path.dropFirst("/api/thumb/".count).dropLast(4)
            guard n.count < 4, n.allSatisfy(\.isASCII), let i = Int(n), i >= 0 else { return reply(.text(404, "Not found")) }
            thumbs.jpeg(feed: i, now: now) { data in
                reply(data.map { HTTPReply(code: 200, type: "image/jpeg", body: $0) } ?? .text(404, "No picture"))
            }
        }
    }

    /// Read-only endpoints take the control token (cookie/header, only while control is on) or the viewer token.
    private func authorizedRead(_ req: WebRequest, viewerToken: String, enabled: Bool) -> Bool {
        if enabled, Self.tokenOK(credential(req), controlToken()) { return true }
        return WebRequest.tokenMatches(provided: req.query["t"], expected: viewerToken)
    }

    private func action(_ req: WebRequest, remote: String, enabled: Bool, now: Date, reply: @escaping (HTTPReply) -> Void) {
        lock.lock(); let okIP = limiter.allowIP(remote, now: now); lock.unlock()
        guard okIP else { return reply(.json(429, ["ok": false, "message": "Too many requests"])) }
        guard req.headers["x-gv-control"] == "1", Self.originOK(origin: req.headers["origin"], host: req.host) else {
            log.add(.action, who: remote, text: "rejected: cross-origin request", ok: false, at: now)
            return reply(.json(403, ["ok": false, "message": "Cross-origin request rejected"]))
        }
        guard enabled else { return reply(.json(403, ["ok": false, "message": "Browser control is off"])) }
        guard Self.tokenOK(credential(req), controlToken()) else {
            log.add(.action, who: remote, text: "rejected: wrong token", ok: false, at: now)
            return reply(.json(401, ["ok": false, "message": "Missing or wrong token"]))
        }
        lock.lock(); let okAll = limiter.allowGlobal(now: now); lock.unlock()
        guard okAll else { return reply(.json(429, ["ok": false, "message": "Too many requests"])) }

        guard req.body.count <= Self.maxBody,
              let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let name = obj["action"] as? String, let act = ControlAction(rawValue: name) else {
            return reply(.json(400, ["ok": false, "message": "Unknown or malformed action"]))
        }
        let feed = obj["feed"] as? Int
        func finish(_ code: Int, _ r: ControlResult, _ extra: [String: Any] = [:]) {
            log.add(.action, who: remote, text: name + (feed.map { " #\($0 + 1)" } ?? "") + ": " + r.message, ok: r.ok)
            reply(.json(code, ["ok": r.ok, "message": r.message].merging(extra) { a, _ in a }))
        }
        if act.destructive, obj["confirm"] as? Bool != true {
            return finish(409, ControlResult(ok: false, message: "Confirmation required"), ["needsConfirm": true])
        }
        if act.needsFeed, feed == nil { return finish(400, ControlResult(ok: false, message: "Feed required")) }
        sink.perform(act, feed: feed) { r in finish(r.ok ? 200 : 422, r) }
    }
}
