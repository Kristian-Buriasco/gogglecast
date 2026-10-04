import Foundation
import CoreMedia
import Network

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
    static let windowSize = 6
    static let retained = 9
    private(set) var segments: [HLSSegment] = []
    private(set) var nextSeq = 0

    mutating func add(duration: Double, data: Data) {
        segments.append(HLSSegment(seq: nextSeq, duration: duration, data: data))
        nextSeq += 1
        if segments.count > Self.retained { segments.removeFirst(segments.count - Self.retained) }
    }

    var listed: [HLSSegment] { Array(segments.suffix(Self.windowSize)) }

    func data(forSequence seq: Int) -> Data? { segments.first { $0.seq == seq }?.data }

    /// nil until the first segment exists (live playlists must not be empty).
    func playlist(token: String) -> String? {
        let l = listed
        guard let first = l.first else { return nil }
        let target = Int(ceil(l.map(\.duration).max() ?? 2))
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first.seq)\n"
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?") // players don't inherit the playlist's query
        for seg in l { s += String(format: "#EXTINF:%.3f,\n", seg.duration) + "seg\(seg.seq).ts\(q)\n" }
        return s
    }
}

/// Cuts the MPEG-TS stream into segments at the first keyframe after `targetDuration`.
/// Each segment starts with PAT/PMT (the muxer emits them on every keyframe) and the
/// parameter sets, so it is independently decodable.
struct HLSSegmenter {
    var targetDuration = 2.0
    private(set) var window = HLSWindow()
    private var muxer = MPEGTSMuxer()
    private var current = Data()
    private var start: Double?

    init(targetDuration: Double = 2.0) { self.targetDuration = targetDuration }

    mutating func push(avcc: Data, isKeyframe: Bool, parameterSets: [Data], pts: Double) {
        if let s = start {
            if isKeyframe, pts - s >= targetDuration {
                window.add(duration: pts - s, data: current)
                current = Data()
                start = pts
            }
        } else {
            guard isKeyframe else { return }
            start = pts
        }
        current.append(muxer.mux(avcc: avcc, isKeyframe: isKeyframe, parameterSets: parameterSets, presentationTime: pts))
    }
}

// MARK: - HTTP parsing / routing (pure)

enum WebRoute: Equatable {
    case page, playlist, segment(Int)
    case notFound, unauthorized, methodNotAllowed, badRequest
}

struct WebRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]

    /// Parses the request line only; headers are irrelevant to this server.
    static func parse(_ head: Data) -> WebRequest? {
        guard let text = String(data: head.prefix(8192), encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/"), parts[1].hasPrefix("/"),
              let c = URLComponents(string: "http://x" + parts[1]) else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        return WebRequest(method: String(parts[0]), path: c.path, query: q)
    }

    static func route(_ r: WebRequest, token: String) -> WebRoute {
        guard r.method == "GET" else { return .methodNotAllowed }
        guard tokenMatches(provided: r.query["t"], expected: token) else { return .unauthorized }
        switch r.path {
        case "/", "/index.html": return .page
        case "/live.m3u8": return .playlist
        default:
            if r.path.hasPrefix("/seg"), r.path.hasSuffix(".ts") {
                let n = r.path.dropFirst(4).dropLast(3)
                if !n.isEmpty, n.count < 10, n.allSatisfy(\.isASCII), let i = Int(n), i >= 0 { return .segment(i) }
            }
            return .notFound
        }
    }

    /// Constant-time in the token length (no early exit); empty expected token = open access.
    static func tokenMatches(provided: String?, expected: String) -> Bool {
        if expected.isEmpty { return true }
        let a = Array((provided ?? "").utf8), b = Array(expected.utf8)
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for i in 0..<max(a.count, b.count) { diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0) }
        return diff == 0
    }
}

enum WebViewerPage {
    static func html(token: String) -> String {
        let q = WebViewerPrefs.tokenSuffix(token, joiner: "?")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>GogglesView</title>
        <style>html,body{margin:0;background:#000;color:#ccc;font:14px -apple-system,sans-serif}video{width:100%;max-height:90vh;background:#000}p{padding:0 12px}</style>
        </head><body>
        <video id="v" controls autoplay muted playsinline></video>
        <p id="m">Waiting for stream...</p>
        <p>Safari / iOS play this natively. Other browsers: open <code>live.m3u8\(q)</code> in VLC (Media &gt; Open Network).</p>
        <script>
        var v=document.getElementById('v'),m=document.getElementById('m'),u='live.m3u8\(q)';
        function go(){fetch(u).then(function(r){if(!r.ok)throw 0;v.src=u;m.textContent='';v.play().catch(function(){})}).catch(function(){setTimeout(go,1000)})}
        if(v.canPlayType('application/vnd.apple.mpegurl'))go();else m.textContent='This browser has no native HLS support.';
        v.addEventListener('error',function(){m.textContent='Stream interrupted, retrying...';setTimeout(go,2000)});
        </script></body></html>
        """
    }
}

// MARK: - Server

/// Opt-in HLS live server. Runs entirely on one private queue; `enqueue` only hops to it.
final class WebViewerServer: ObservableObject, SampleBufferRendering {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private static let maxConnections = 32

    private let queue = DispatchQueue(label: "WebViewerServer")
    private var listener: NWListener?
    private var segmenter = HLSSegmenter()
    private var token = ""
    private var connections = Set<ObjectIdentifier>()

    func start(port: Int, allowLAN: Bool, token: String) {
        queue.async { [self] in
            stopLocked()
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
                publish(error: "Invalid port"); return
            }
            self.token = token
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
        switch WebRequest.route(req, token: token) {
        case .page: reply(c, 200, "OK", "text/html; charset=utf-8", Data(WebViewerPage.html(token: token).utf8))
        case .playlist:
            if let pl = segmenter.window.playlist(token: token) {
                reply(c, 200, "OK", "application/vnd.apple.mpegurl", Data(pl.utf8))
            } else { reply(c, 404, "Not Found", "text/plain", Data("No segments yet".utf8)) }
        case .segment(let n):
            if let d = segmenter.window.data(forSequence: n) { reply(c, 200, "OK", "video/mp2t", d) }
            else { reply(c, 404, "Not Found", "text/plain", Data("Gone".utf8)) }
        case .notFound: reply(c, 404, "Not Found", "text/plain", Data("Not found".utf8))
        case .unauthorized: reply(c, 401, "Unauthorized", "text/plain", Data("Missing or wrong token".utf8))
        case .methodNotAllowed: reply(c, 405, "Method Not Allowed", "text/plain", Data("GET only".utf8))
        case .badRequest: reply(c, 400, "Bad Request", "text/plain", Data("Bad request".utf8))
        }
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
