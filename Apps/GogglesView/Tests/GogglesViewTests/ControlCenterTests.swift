import Testing
import Foundation
import CoreVideo
@testable import GogglesView

private final class FakeSink: ControlSink {
    var calls: [(ControlAction, Int?)] = []
    var result = ControlResult(ok: true, message: "done")
    private let lock = NSLock()
    func perform(_ action: ControlAction, feed: Int?, completion: @escaping (ControlResult) -> Void) {
        lock.lock(); calls.append((action, feed)); lock.unlock()
        completion(result)
    }
}

private func frame(_ w: Int = 64, _ h: Int = 48) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &b)
    CVPixelBufferLockBaseAddress(b!, [])
    memset(CVPixelBufferGetBaseAddress(b!), 0x80, CVPixelBufferGetBytesPerRow(b!) * h)
    CVPixelBufferUnlockBaseAddress(b!, [])
    return b!
}

@Suite("ControlCenter", .serialized)
struct ControlCenterTests {
    static let host = "192.168.1.5:8787"

    private func make(enabled: Bool = true, capacity: Int = 200) -> (ControlService, FakeSink) {
        let sink = FakeSink()
        let s = ControlService(sink: sink, log: ControlLog(capacity: capacity))
        s.isEnabled = { enabled }
        s.controlToken = { "ctok" }
        return (s, sink)
    }

    private func call(_ s: ControlService, _ method: String, _ path: String, query: [String: String] = [:],
                      headers: [String: String] = [:], body: String = "", ip: String = "10.0.0.2", now: Date = Date()) async -> HTTPReply {
        let req = WebRequest(method: method, path: path, query: query, host: Self.host, headers: headers, body: Data(body.utf8))
        return await withCheckedContinuation { c in s.handle(req, remote: ip, viewerToken: "vtok", now: now) { c.resume(returning: $0) } }
    }

    private func post(_ s: ControlService, _ json: String, extra: [String: String] = [:], ip: String = "10.0.0.2", now: Date = Date()) async -> HTTPReply {
        var h = ["cookie": "gv_control=ctok", "x-gv-control": "1", "origin": "http://" + Self.host]
        h.merge(extra) { $1 }
        return await call(s, "POST", "/api/action", headers: h, body: json, ip: ip, now: now)
    }

    @Test func controlsDisabledByDefaultSetting() async {
        let (s, sink) = make(enabled: false)
        #expect(await call(s, "GET", "/control", query: ["c": "ctok"]).code == 403)
        #expect(await post(s, #"{"action":"away.on"}"#).code == 403)
        #expect(sink.calls.isEmpty)
        #expect(await call(s, "GET", "/api/state").code == 401) // no token, nothing leaks
        #expect(await call(s, "GET", "/api/state", query: ["t": "vtok"]).code == 200) // viewer token still reads
    }

    @Test func tokenRequiredAndMovedToCookie() async {
        let (s, sink) = make()
        #expect(await call(s, "GET", "/control").code == 401)
        #expect(await call(s, "GET", "/control", query: ["c": "wrong"]).code == 401)
        let ok = await call(s, "GET", "/control", query: ["c": "ctok"])
        #expect(ok.code == 302 && ok.headers["Location"] == "/control")
        #expect(ok.headers["Set-Cookie"]?.contains("gv_control=ctok") == true && ok.headers["Set-Cookie"]?.contains("HttpOnly") == true)
        let page = await call(s, "GET", "/control", headers: ["cookie": "a=b; gv_control=ctok"])
        #expect(page.code == 200 && page.type.hasPrefix("text/html"))
        #expect(await call(s, "GET", "/control", headers: ["cookie": "gv_control=nope"]).code == 401)
        // POST without or with a wrong token never reaches the sink; the viewer token is no substitute.
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["cookie": ""]).code == 401)
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["cookie": "gv_control=vtok"]).code == 401)
        #expect(sink.calls.isEmpty)
        #expect(!ControlService.tokenOK("", "") && !ControlService.tokenOK(nil, "") && ControlService.tokenOK("x", "x") && !ControlService.tokenOK("x", "xy"))
    }

    @Test func crossOriginAndMethodRejected() async {
        let (s, sink) = make()
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["origin": "http://evil.example"]).code == 403)
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["origin": "http://192.168.1.5:9999"]).code == 403)
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["origin": "null"]).code == 403)
        #expect(await post(s, #"{"action":"away.on"}"#, extra: ["x-gv-control": ""]).code == 403)
        #expect(await call(s, "GET", "/api/action", headers: ["cookie": "gv_control=ctok"]).code == 405)
        #expect(sink.calls.isEmpty)
        #expect(await post(s, #"{"action":"away.on"}"#).code == 200)
        #expect(sink.calls.count == 1)
    }

    @Test func destructiveActionsNeedConfirm() async {
        let (s, sink) = make()
        for a in ["record.stop", "outputs.hide", "reconnect", "away.off"] {
            let r = await post(s, #"{"action":"\#(a)","feed":0}"#, now: Date(timeIntervalSince1970: Double(sink.calls.count) * 10))
            #expect(r.code == 409, "\(a)")
        }
        #expect(sink.calls.isEmpty)
        let r = await post(s, #"{"action":"record.stop","feed":0,"confirm":true}"#, now: Date(timeIntervalSince1970: 100))
        #expect(r.code == 200 && sink.calls.count == 1)
        #expect(!ControlAction.recordStart.destructive && ControlAction.recordStop.destructive)
    }

    @Test func rateLimitPerIPAndGlobal() async {
        let (s, sink) = make()
        let t = Date(timeIntervalSince1970: 1000)
        var codes: [Int] = []
        for _ in 0..<7 { codes.append(await post(s, #"{"action":"alerts.test"}"#, now: t).code) }
        #expect(codes == [200, 200, 200, 200, 200, 429, 429])
        #expect(await post(s, #"{"action":"alerts.test"}"#, ip: "10.0.0.9", now: t).code == 200) // another address has its own budget
        #expect(await post(s, #"{"action":"alerts.test"}"#, now: t.addingTimeInterval(1.1)).code == 200) // window slides
        #expect(sink.calls.count == 7)
        // Global cap: 10 per second over all addresses.
        var l = ControlRateLimiter()
        let g = (0..<12).map { i in l.allowGlobal(now: t.addingTimeInterval(Double(i) * 0.01)) }
        #expect(g.filter { $0 }.count == 10)
    }

    @Test func everyActionIsRoutedToTheSink() async {
        let (s, sink) = make()
        var t = 0.0
        for a in ControlAction.allCases {
            t += 2
            let feed = a.needsFeed ? ",\"feed\":2" : ""
            let r = await post(s, "{\"action\":\"\(a.rawValue)\",\"confirm\":true\(feed)}", now: Date(timeIntervalSince1970: t))
            #expect(r.code == 200, "\(a)")
        }
        #expect(sink.calls.map(\.0) == ControlAction.allCases)
        #expect(sink.calls.filter { $0.0.needsFeed }.allSatisfy { $0.1 == 2 })
        #expect(await post(s, #"{"action":"record.start"}"#, now: Date(timeIntervalSince1970: 500)).code == 400) // feed required
        #expect(await post(s, #"{"action":"format.disk"}"#, now: Date(timeIntervalSince1970: 502)).code == 400)
        #expect(await post(s, "not json", now: Date(timeIntervalSince1970: 504)).code == 400)
        // A refused action comes back as ok:false with the reason.
        sink.result = ControlResult(ok: false, message: "Feed is not live")
        let r = await post(s, #"{"action":"screenshot","feed":0}"#, now: Date(timeIntervalSince1970: 506))
        let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        #expect(r.code == 422 && obj?["ok"] as? Bool == false && obj?["message"] as? String == "Feed is not live")
    }

    @Test func stateJSONHasNoSerials() throws {
        let rows = [OverviewRow(id: "SERIAL-0123456789", name: "DJI Goggles 3 (…6789)", status: "Live", health: .good, isLive: true,
                                fps: 60, battery: 80, isRecording: true, elapsed: 65, issues: [.frozenPicture],
                                outputs: [OutputChip(name: "SRT", state: .on)], drops: 2, bitrateKbps: 9000)]
        let log = [ControlLogEntry(time: Date(), kind: .signal, who: "system", text: "Signal lost: Stage", ok: false)]
        let d = ControlState.data(rows: rows, names: ["Stage"], globals: .init(extraOutputs: [OutputChip(name: "HDMI 1", state: .error), OutputChip(name: "SRT", state: .off)]),
                                  log: log, now: Date())
        let text = String(decoding: d, as: UTF8.self)
        #expect(!text.contains("SERIAL") && !text.contains("6789") && !text.contains("DJI"))
        let o = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        let f = try #require((o["feeds"] as? [[String: Any]])?.first)
        #expect(f["name"] as? String == "Stage" && f["recording"] as? Bool == true && f["elapsed"] as? Int == 65 && f["dropped"] as? Int == 2)
        let outs = (o["outputs"] as? [[String: String]]) ?? []
        #expect(outs.contains { $0["name"] == "SRT" && $0["state"] == "on" } && outs.contains { $0["name"] == "HDMI 1" && $0["state"] == "error" })
        #expect(o["health"] as? String == "good" && (o["log"] as? [Any])?.count == 1)
    }

    @Test func thumbnailsAreJPEGAndRateLimited() async {
        let (s, _) = make()
        var provided = 0
        s.thumbs.frameProvider = { i in provided += 1; return i == 0 ? frame() : nil }
        let t = Date(timeIntervalSince1970: 2000)
        let a = await call(s, "GET", "/api/thumb/0.jpg", headers: ["cookie": "gv_control=ctok"], now: t)
        #expect(a.code == 200 && a.type == "image/jpeg")
        #expect(Array(a.body.prefix(3)) == [0xFF, 0xD8, 0xFF])
        _ = await call(s, "GET", "/api/thumb/0.jpg", headers: ["cookie": "gv_control=ctok"], now: t.addingTimeInterval(0.5))
        #expect(provided == 1, "second request within a second is served from the cache")
        _ = await call(s, "GET", "/api/thumb/0.jpg", headers: ["cookie": "gv_control=ctok"], now: t.addingTimeInterval(1.5))
        #expect(provided == 2)
        #expect(await call(s, "GET", "/api/thumb/1.jpg", headers: ["cookie": "gv_control=ctok"], now: t).code == 404) // no frame
        #expect(await call(s, "GET", "/api/thumb/0.jpg").code == 401)
        #expect(await call(s, "GET", "/api/thumb/x.jpg", headers: ["cookie": "gv_control=ctok"]).code == 404)
    }

    @Test func logRingIsCapped() {
        let log = ControlLog(capacity: 5)
        for i in 0..<20 { log.add(i % 2 == 0 ? .action : .alert, who: "10.0.0.1", text: "n\(i)") }
        #expect(log.count == 5)
        #expect(log.recent(50).map(\.text) == ["n19", "n18", "n17", "n16", "n15"])
        #expect(log.recent(50, kind: .action).map(\.text) == ["n18", "n16"])
    }

    @Test func actionsAreLogged() async {
        let (s, _) = make()
        _ = await post(s, #"{"action":"record.start","feed":1}"#)
        _ = await post(s, #"{"action":"record.start","feed":1}"#, extra: ["cookie": ""])
        let e = s.log.recent(10)
        #expect(e.count == 2 && e[0].text.contains("wrong token") && !e[0].ok)
        #expect(e[1].who == "10.0.0.2" && e[1].text.hasPrefix("record.start #2"))
    }

    @Test func serverOverLoopbackEnforcesBodyLimitAndAuth() async throws {
        let (service, sink) = make()
        let server = WebViewerServer()
        server.control = service
        server.start(port: 18093, allowLAN: false, token: "vtok")
        for _ in 0..<50 where !server.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(server.isRunning, "\(server.lastError ?? "")")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        func send(_ body: String, cookie: String? = "gv_control=ctok", control: Bool = true) async throws -> Int {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:18093/api/action")!)
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
            if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if control { req.setValue("1", forHTTPHeaderField: "X-GV-Control") }
            let (_, r) = try await session.data(for: req)
            return (r as! HTTPURLResponse).statusCode
        }
        #expect(try await send(#"{"action":"alerts.test"}"#) == 200)
        #expect(sink.calls.count == 1)
        #expect(try await send(#"{"action":"alerts.test"}"#, cookie: nil) == 401)
        #expect(try await send(#"{"action":"alerts.test"}"#, control: false) == 403)
        #expect(try await send(String(repeating: "x", count: 5000)) == 413)
        #expect(sink.calls.count == 1)
        var get = URLRequest(url: URL(string: "http://127.0.0.1:18093/control")!)
        get.setValue("gv_control=ctok", forHTTPHeaderField: "Cookie")
        let (page, r) = try await session.data(for: get)
        #expect((r as! HTTPURLResponse).statusCode == 200 && String(decoding: page, as: UTF8.self).contains("/api/action"))
        server.stop()
    }
}
