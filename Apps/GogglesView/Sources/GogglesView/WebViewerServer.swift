import Foundation
import CoreMedia
import Network
import Security

enum WebViewerPrefs {
    static let enabledKey = "webViewerEnabled"
    static let portKey = "webViewerPort"
    static let lanKey = "webViewerLAN"
    static let tokenKey = "webViewerToken"
    static var port: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(p) ? p : 8080
    }
    static var lan: Bool { UserDefaults.standard.bool(forKey: lanKey) }
    static var token: String { SecretStore.get(tokenKey) }

    /// `Name.local` (Bonjour) regardless of whether the system hostname carries a domain.
    static var localHostname: String {
        let h = ProcessInfo.processInfo.hostName
        let first = h.split(separator: ".").first.map(String.init) ?? h
        return first.isEmpty ? "localhost" : first + ".local"
    }

    static func viewerURL(host: String, port: Int, token: String) -> String {
        "http://\(host):\(port)/" + tokenSuffix(token, joiner: "?")
    }

    /// 128-bit random hex token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The stored token, or a fresh one when none is stored (several views may race to create it).
    static func existingOrNewToken() -> String {
        let t = token
        return t.isEmpty ? generateToken() : t
    }

    /// The viewer needs a token whenever it is enabled and reachable from other devices; an empty token
    /// is only acceptable in localhost-only mode (where the Host check still applies).
    static func tokenRequired(allowLAN: Bool) -> Bool { allowLAN }

    static func tokenSuffix(_ token: String, joiner: String) -> String {
        token.isEmpty ? "" : joiner + "t=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }
}

// MARK: - HLS segmenting (pure)

struct HLSSegment: Equatable {
    let seq: Int
    let duration: Double
    let data: Data
}

/// Sliding window of finished segments. The playlist lists the newest `windowSize`;
/// a few extra are retained so a client mid-download of the oldest entry still succeeds.
struct HLSWindow {
    static let windowSize = 8
    static let retained = 12
    private(set) var segments: [HLSSegment] = []
    private(set) var nextSeq = 0

    mutating func add(duration: Double, data: Data) {
        segments.append(HLSSegment(seq: nextSeq, duration: duration, data: data))
        nextSeq += 1
        if segments.count > Self.retained { segments.removeFirst(segments.count - Self.retained) }
    }

    var listed: [HLSSegment] { Array(segments.suffix(Self.windowSize)) }

    /// Where players should begin, in seconds from the end of the playlist (negative).
    static let startOffset = -3.0

    func data(forSequence seq: Int) -> Data? { segments.first { $0.seq == seq }?.data }

    /// nil until the first segment exists (live playlists must not be empty).
    func playlist(token: String) -> String? {
        let l = listed
        guard let first = l.first else { return nil }
        // RFC 8216: every EXTINF, rounded to the nearest integer, must not exceed TARGETDURATION. Rounding
        // (not ceil) keeps 1.03 s segments at a target of 1, which is what sets Safari's start-up hold-back.
        let target = max(1, Int((l.map(\.duration).max() ?? 1).rounded()))
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first.seq)\n"
        s += "#EXT-X-START:TIME-OFFSET=\(Int(Self.startOffset)),PRECISE=NO\n"
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?") // players don't inherit the playlist's query
        for seg in l { s += String(format: "#EXTINF:%.3f,\n", seg.duration) + "seg\(seg.seq).ts\(q)\n" }
        return s
    }
}

/// Cuts the MPEG-TS stream into segments at the first keyframe after `targetDuration`.
/// Each segment starts with PAT/PMT (the muxer emits them on every keyframe) and the
/// parameter sets, so it is independently decodable.
struct HLSSegmenter {
    /// If keyframes stop arriving the open segment would grow forever; past this size it is dropped
    /// and the segmenter waits for the next keyframe.
    static let defaultMaxSegmentBytes = 8_000_000
    /// The encoder emits a keyframe every second, so segments are cut on every keyframe.
    static let defaultTargetDuration = 1.0
    /// Timestamps jitter by a frame or so; without slack a 0.99 s gap would skip a keyframe and make 2 s segments.
    static let cutSlack = 0.05

    var targetDuration = HLSSegmenter.defaultTargetDuration
    var maxSegmentBytes = HLSSegmenter.defaultMaxSegmentBytes
    private(set) var window = HLSWindow()
    private var muxer = MPEGTSMuxer()
    private var current = Data()
    private var start: Double?

    /// Bytes buffered in the open (unpublished) segment.
    var pendingBytes: Int { current.count }

    init(targetDuration: Double = HLSSegmenter.defaultTargetDuration, maxSegmentBytes: Int = HLSSegmenter.defaultMaxSegmentBytes) {
        self.targetDuration = targetDuration
        self.maxSegmentBytes = maxSegmentBytes
    }

    mutating func push(avcc: Data, isKeyframe: Bool, parameterSets: [Data], pts: Double) {
        if let s = start {
            if isKeyframe, pts - s >= targetDuration - Self.cutSlack {
                window.add(duration: pts - s, data: current)
                current = Data()
                start = pts
            }
        } else {
            guard isKeyframe else { return }
            start = pts
        }
        current.append(muxer.mux(avcc: avcc, isKeyframe: isKeyframe, parameterSets: parameterSets, presentationTime: pts))
        if current.count > maxSegmentBytes {
            current = Data()
            start = nil // wait for the next keyframe
        }
    }
}

// MARK: - HTTP parsing / routing (pure)

enum WebRoute: Equatable {
    case page, playlist, segment(Int), manifest, icon(Int), statusPage, statusJSON
    case notFound, unauthorized, methodNotAllowed, badRequest
}

struct WebRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    /// Value of the `Host` header, if present.
    var host: String? = nil

    /// Parses the request line and the Host header.
    static func parse(_ head: Data) -> WebRequest? {
        guard let text = String(data: head.prefix(8192), encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/"), parts[1].hasPrefix("/"),
              let c = URLComponents(string: "http://x" + parts[1]) else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        var host: String?
        for h in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = h.firstIndex(of: ":"), h[..<colon].lowercased() == "host" else { continue }
            host = h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            break
        }
        return WebRequest(method: String(parts[0]), path: c.path, query: q, host: host)
    }

    static func route(_ r: WebRequest, token: String) -> WebRoute {
        guard r.method == "GET" else { return .methodNotAllowed }
        guard tokenMatches(provided: r.query["t"], expected: token) else { return .unauthorized }
        switch r.path {
        case "/", "/index.html": return .page
        case "/live.m3u8": return .playlist
        case "/status", "/status.html": return .statusPage
        case "/status.json": return .statusJSON
        case "/manifest.webmanifest": return .manifest
        case "/icon-180.png": return .icon(180)
        case "/icon-512.png": return .icon(512)
        default:
            if r.path.hasPrefix("/seg"), r.path.hasSuffix(".ts") {
                let n = r.path.dropFirst(4).dropLast(3)
                if !n.isEmpty, n.count < 10, n.allSatisfy(\.isASCII), let i = Int(n), i >= 0 { return .segment(i) }
            }
            return .notFound
        }
    }

    /// No early exit on the bytes; the length difference is compared as a Bool (it used to be XORed
    /// into 8 bits, which a length difference of 256 would cancel). Empty expected token = open access.
    static func tokenMatches(provided: String?, expected: String) -> Bool {
        if expected.isEmpty { return true }
        let a = Array((provided ?? "").utf8), b = Array(expected.utf8)
        let sameLength = a.count == b.count
        var diff: UInt8 = 0
        for i in 0..<max(a.count, b.count) { diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0) }
        return sameLength && diff == 0
    }
}

/// Host-header validation: a web page on another origin that rebinds its DNS name to this machine
/// still sends its own name in `Host`, so it is rejected.
enum WebHostPolicy {
    /// Lower-cased host with port, brackets and a trailing dot removed; nil if empty/malformed.
    static func normalize(_ header: String?) -> String? {
        guard var h = header?.trimmingCharacters(in: .whitespaces).lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return nil }
            h = String(h[h.index(after: h.startIndex)..<close])
        } else if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") {
            h = String(h[..<colon])
        }
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// `localAddresses` are literal IPs of this machine; `hostnames` are names it answers to
    /// (`<hostname>.local`). Only consulted when `allowLAN` is on.
    static func isAllowed(hostHeader: String?, allowLAN: Bool, hostnames: [String], localAddresses: [String]) -> Bool {
        guard let h = normalize(hostHeader) else { return false }
        if loopbackNames.contains(h) { return true }
        guard allowLAN else { return false }
        return hostnames.contains { $0.lowercased() == h } || localAddresses.contains { $0.lowercased() == h }
    }

    /// Literal IPv4/IPv6 addresses of this machine's interfaces.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            if let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    var a = String(cString: buf)
                    if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) } // strip zone id
                    out.append(a)
                }
            }
            p = i.pointee.ifa_next
        }
        return out
    }

    static func hostnames() -> [String] {
        let h = ProcessInfo.processInfo.hostName.lowercased()
        let first = h.split(separator: ".").first.map(String.init) ?? h
        return [WebViewerPrefs.localHostname, h, first.isEmpty ? "" : first + ".local"].filter { !$0.isEmpty }
    }
}

// MARK: - Server

/// Opt-in HLS live server. Runs entirely on one private queue; `enqueue` only hops to it.
final class WebViewerServer: ObservableObject, SampleBufferRendering {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    init() {
        OutputActivityBoard.shared.register(self) { [weak self] in self?.isRunning == true }
    }
    deinit { OutputActivityBoard.shared.unregister(self) }

    private static let maxConnections = 32

    private let queue = DispatchQueue(label: "WebViewerServer")
    private var listener: NWListener?
    private var segmenter = HLSSegmenter()
    private var token = ""
    private var allowLAN = false
    private var connections = Set<ObjectIdentifier>()

    func start(port: Int, allowLAN: Bool, token: String) {
        queue.async { [self] in
            stopLocked()
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
                publish(error: L("Invalid port")); return
            }
            if WebViewerPrefs.tokenRequired(allowLAN: allowLAN) && token.isEmpty {
                publish(error: L("Set an access token before allowing other devices")); return
            }
            self.token = token
            self.allowLAN = allowLAN
            segmenter = HLSSegmenter()
            do {
                let params = NWParameters.tcp
                if !allowLAN { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p) }
                let l = allowLAN ? try NWListener(using: params, on: p) : try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.queue.async { self?.accept(c) } }
                l.stateUpdateHandler = { [weak self, weak l] st in
                    guard let self, let l else { return }
                    self.queue.async {
                        guard l === self.listener else { return }
                        switch st {
                        case .ready: DispatchQueue.main.async { self.isRunning = true; self.lastError = nil }
                        case .failed(let e): self.stopLocked(); self.publish(error: e.localizedDescription)
                        default: break
                        }
                    }
                }
                // Advertised only while other devices are allowed; cancelling the listener withdraws it.
                if allowLAN { l.service = WebViewerBonjour.service() }
                listener = l
                l.start(queue: queue)
            } catch {
                publish(error: error.localizedDescription)
            }
        }
    }

    func stop() { queue.async { [self] in stopLocked() } }

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        connections.removeAll()
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func publish(error: String?) { DispatchQueue.main.async { self.lastError = error } }

    // MARK: connections

    private func accept(_ c: NWConnection) {
        guard connections.count < Self.maxConnections else { c.cancel(); return }
        let id = ObjectIdentifier(c)
        connections.insert(id)
        c.stateUpdateHandler = { [weak self] st in
            if case .cancelled = st { self?.queue.async { self?.connections.remove(id) } }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { c.cancel() } // slow-loris guard
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            self.queue.async {
                var buf = buffer
                if let data { buf.append(data) }
                if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(c, to: WebRequest.parse(buf))
                } else if err != nil || done || buf.count > 16_384 {
                    c.cancel()
                } else {
                    self.receive(c, buffer: buf)
                }
            }
        }
    }

    private func respond(_ c: NWConnection, to req: WebRequest?) {
        guard let req else { return reply(c, 400, "Bad Request", "text/plain", Data("Bad request".utf8)) }
        guard hostAllowed(req.host) else {
            return reply(c, 421, "Misdirected Request", "text/plain", Data("Unexpected Host header".utf8))
        }
        switch WebRequest.route(req, token: token) {
        case .page: reply(c, 200, "OK", "text/html; charset=utf-8", Data(WebViewerPage.html(token: token).utf8))
        case .statusPage: reply(c, 200, "OK", "text/html; charset=utf-8", Data(WebStatusPage.html(token: token).utf8))
        case .statusJSON: reply(c, 200, "OK", "application/json", WebStatusStore.latest)
        case .playlist:
            if let pl = segmenter.window.playlist(token: token) {
                reply(c, 200, "OK", "application/vnd.apple.mpegurl", Data(pl.utf8))
            } else { reply(c, 404, "Not Found", "text/plain", Data("No segments yet".utf8)) }
        case .segment(let n):
            if let d = segmenter.window.data(forSequence: n) { reply(c, 200, "OK", "video/mp2t", d) }
            else { reply(c, 404, "Not Found", "text/plain", Data("Gone".utf8)) }
        case .manifest:
            reply(c, 200, "OK", "application/manifest+json", Data(WebViewerPage.manifest(token: token).utf8))
        case .icon(let size):
            if let png = WebViewerIcon.png(size: size) { reply(c, 200, "OK", "image/png", png) }
            else { reply(c, 404, "Not Found", "text/plain", Data("Not found".utf8)) }
        case .notFound: reply(c, 404, "Not Found", "text/plain", Data("Not found".utf8))
        case .unauthorized: reply(c, 401, "Unauthorized", "text/plain", Data("Missing or wrong token".utf8))
        case .methodNotAllowed: reply(c, 405, "Method Not Allowed", "text/plain", Data("GET only".utf8))
        case .badRequest: reply(c, 400, "Bad Request", "text/plain", Data("Bad request".utf8))
        }
    }

    private func hostAllowed(_ host: String?) -> Bool {
        if WebHostPolicy.isAllowed(hostHeader: host, allowLAN: false, hostnames: [], localAddresses: []) { return true }
        guard allowLAN else { return false }
        return WebHostPolicy.isAllowed(hostHeader: host, allowLAN: true,
                                       hostnames: WebHostPolicy.hostnames(), localAddresses: WebHostPolicy.localAddresses())
    }

    private func reply(_ c: NWConnection, _ code: Int, _ reason: String, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache, no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let avcc = NetworkStreamer.avccData(sampleBuffer) else { return }
        let isKey = NetworkStreamer.isKeyframe(sampleBuffer)
        let ps = isKey ? NetworkStreamer.parameterSets(sampleBuffer) : []
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        submit(avcc: avcc, isKeyframe: isKey, parameterSets: ps, pts: pts)
    }

    func submit(avcc: Data, isKeyframe: Bool, parameterSets: [Data], pts: Double) {
        queue.async { [self] in
            guard listener != nil else { return }
            segmenter.push(avcc: avcc, isKeyframe: isKeyframe, parameterSets: parameterSets, pts: pts)
        }
    }

    func flush() {}
}
