import Testing
import Foundation
@testable import GogglesView

@Suite("WebViewer")
struct WebViewerTests {
    static func window(_ n: Int) -> HLSWindow {
        var w = HLSWindow()
        for i in 0..<n { w.add(duration: 2.0 + Double(i % 2) * 0.4, data: Data([UInt8(i)])) }
        return w
    }

    @Test func playlistFormat() {
        #expect(HLSWindow().playlist(token: "") == nil)
        let p = Self.window(2).playlist(token: "")!
        #expect(p == "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2.000,\nseg0.ts\n#EXTINF:2.400,\nseg1.ts\n")
        #expect(Self.window(1).playlist(token: "a b")!.contains("seg0.ts?t=a%20b\n"))
    }

    @Test func slidingWindow() {
        let w = Self.window(20)
        #expect(w.listed.map(\.seq) == Array(14...19))
        let p = w.playlist(token: "")!
        #expect(p.contains("MEDIA-SEQUENCE:14") && !p.contains("seg13.ts"))
        #expect(w.data(forSequence: 19) == Data([19]))
        #expect(w.data(forSequence: 11) != nil) // retained beyond the listed window
        #expect(w.data(forSequence: 5) == nil)
        #expect(w.segments.count == HLSWindow.retained)
    }

    @Test func segmenterCutsAtKeyframes() {
        var s = HLSSegmenter(targetDuration: 2)
        let nal = Data([0, 0, 0, 2, 0x65, 0x88])
        let ps = [Data([0x67, 0x64, 0, 0x28]), Data([0x68, 0xEE, 0x3C, 0x80])]
        s.push(avcc: nal, isKeyframe: false, parameterSets: [], pts: 0) // before first key: dropped
        for i in 0..<150 { // 30 fps, keyframe every 30 frames (1 s)
            s.push(avcc: nal, isKeyframe: i % 30 == 0, parameterSets: i % 30 == 0 ? ps : [], pts: 10 + Double(i) / 30)
        }
        let segs = s.window.segments
        #expect(segs.count == 2) // cuts at t=2 and t=4; the open one isn't published
        #expect(segs.allSatisfy { abs($0.duration - 2) < 0.001 })
        for seg in segs {
            #expect(seg.data.count % 188 == 0)
            #expect(seg.data[0] == 0x47 && seg.data[1] == 0x40 && seg.data[2] == 0) // starts with PAT
        }
    }

    @Test func requestParsingAndRouting() {
        let r = WebRequest.parse(Data("GET /live.m3u8?t=abc HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        #expect(r == WebRequest(method: "GET", path: "/live.m3u8", query: ["t": "abc"], host: "x"))
        #expect(WebRequest.parse(Data("garbage\r\n\r\n".utf8)) == nil)
        #expect(WebRequest.parse(Data("GET nope HTTP/1.1\r\n\r\n".utf8)) == nil)
        func route(_ m: String, _ p: String, _ q: [String: String] = [:], _ tok: String = "") -> WebRoute {
            WebRequest.route(WebRequest(method: m, path: p, query: q), token: tok)
        }
        #expect(route("GET", "/") == .page)
        #expect(route("GET", "/live.m3u8") == .playlist)
        #expect(route("GET", "/seg42.ts") == .segment(42))
        #expect(route("GET", "/seg-1.ts") == .notFound)
        #expect(route("GET", "/seg.ts") == .notFound)
        #expect(route("GET", "/../etc/passwd") == .notFound)
        #expect(route("POST", "/") == .methodNotAllowed)
        #expect(route("GET", "/", [:], "s3") == .unauthorized)
        #expect(route("GET", "/", ["t": "nope"], "s3") == .unauthorized)
        #expect(route("GET", "/live.m3u8", ["t": "s3"], "s3") == .playlist)
    }

    @Test func tokenCompare() {
        #expect(WebRequest.tokenMatches(provided: nil, expected: ""))
        #expect(WebRequest.tokenMatches(provided: "abc", expected: "abc"))
        #expect(!WebRequest.tokenMatches(provided: "abd", expected: "abc"))
        #expect(!WebRequest.tokenMatches(provided: "abcd", expected: "abc"))
        #expect(!WebRequest.tokenMatches(provided: "ab", expected: "abc"))
        #expect(!WebRequest.tokenMatches(provided: nil, expected: "abc"))
    }

    @Test func tokenCompareIgnoresLengthWrapAround() {
        // Lengths differing by exactly 256 used to cancel out in the 8-bit XOR.
        let long = String(repeating: "a", count: 259)
        #expect(!WebRequest.tokenMatches(provided: long, expected: "aaa"))
        #expect(!WebRequest.tokenMatches(provided: "aaa", expected: long))
        #expect(WebRequest.tokenMatches(provided: long, expected: long))
        #expect(!WebRequest.tokenMatches(provided: "", expected: "x"))
    }

    @Test func hostHeaderParsing() {
        let r = WebRequest.parse(Data("GET / HTTP/1.1\r\nAccept: */*\r\nhOsT:  Foo.local:8080 \r\n\r\n".utf8))
        #expect(r?.host == "Foo.local:8080")
        #expect(WebRequest.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8))?.host == nil)
    }

    @Test func hostPolicyLocalhostOnly() {
        func ok(_ h: String?) -> Bool { WebHostPolicy.isAllowed(hostHeader: h, allowLAN: false, hostnames: ["mac.local"], localAddresses: ["192.168.1.5"]) }
        #expect(ok("localhost:8080") && ok("127.0.0.1:8080") && ok("[::1]:8080") && ok("::1") && ok("LOCALHOST"))
        #expect(!ok(nil) && !ok("") && !ok("evil.example:8080") && !ok("localhost.evil.example"))
        // LAN names and IPs are not accepted when LAN mode is off.
        #expect(!ok("mac.local") && !ok("192.168.1.5:8080"))
    }

    @Test func hostPolicyLAN() {
        func ok(_ h: String?) -> Bool { WebHostPolicy.isAllowed(hostHeader: h, allowLAN: true, hostnames: ["mac.local"], localAddresses: ["192.168.1.5", "fe80::1"]) }
        #expect(ok("mac.local:8080") && ok("MAC.local.") && ok("192.168.1.5:8080") && ok("[fe80::1]:8080") && ok("localhost"))
        #expect(!ok("attacker.example") && !ok("192.168.1.6") && !ok(nil) && !ok("mac.local.evil.example"))
    }

    @Test func serverRejectsForeignHostAndRequiresTokenForLAN() async throws {
        let server = WebViewerServer()
        server.start(port: 18091, allowLAN: false, token: "")
        for _ in 0..<50 where !server.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(server.isRunning, "\(server.lastError ?? "")")
        func status(host: String) async throws -> Int {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:18091/")!)
            req.setValue(host, forHTTPHeaderField: "Host")
            let (_, r) = try await URLSession.shared.data(for: req)
            return (r as! HTTPURLResponse).statusCode
        }
        #expect(try await status(host: "evil.example") == 421)
        #expect(try await status(host: "localhost:18091") == 200)
        server.stop()
        let lan = WebViewerServer()
        lan.start(port: 18092, allowLAN: true, token: "")
        for _ in 0..<50 where lan.lastError == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(!lan.isRunning)
        #expect(lan.lastError != nil)
    }

    @Test func generatedTokensAreRandomHex() {
        let a = WebViewerPrefs.generateToken(), b = WebViewerPrefs.generateToken()
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit))
        #expect(a != b)
        #expect(WebViewerPrefs.tokenRequired(allowLAN: true) && !WebViewerPrefs.tokenRequired(allowLAN: false))
    }

    @Test func segmenterDropsRunawaySegmentWhenKeyframesStop() {
        var s = HLSSegmenter(targetDuration: 2, maxSegmentBytes: 20_000)
        let big = Data([0, 0, 0, 2, 0x65, 0x88])
        let ps = [Data([0x67, 0x64, 0, 0x28]), Data([0x68, 0xEE, 0x3C, 0x80])]
        s.push(avcc: big, isKeyframe: true, parameterSets: ps, pts: 0)
        let frame = Data([0, 0, 0, 2, 0x41, 0x9A]) + Data(repeating: 0xAB, count: 500)
        var maxPending = 0
        for i in 1..<2000 {
            s.push(avcc: frame, isKeyframe: false, parameterSets: [], pts: Double(i) / 30)
            maxPending = max(maxPending, s.pendingBytes)
        }
        #expect(maxPending <= 20_000 + 2_000)
        #expect(s.window.segments.isEmpty)
        // After the drop, the next keyframe restarts a segment.
        s.push(avcc: big, isKeyframe: true, parameterSets: ps, pts: 100)
        #expect(s.pendingBytes > 0)
    }

    @Test func serverServesOverLoopback() async throws {
        let server = WebViewerServer()
        server.start(port: 18089, allowLAN: false, token: "tok")
        for _ in 0..<50 where !server.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(server.isRunning, "\(server.lastError ?? "")")
        let nal = Data([0, 0, 0, 2, 0x65, 0x88])
        let ps = [Data([0x67, 0x64, 0, 0x28]), Data([0x68, 0xEE, 0x3C, 0x80])]
        for i in 0..<130 { server.submit(avcc: nal, isKeyframe: i % 30 == 0, parameterSets: i % 30 == 0 ? ps : [], pts: Double(i) / 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        func get(_ p: String) async throws -> (Int, Data) {
            let (d, r) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18089\(p)")!)
            return ((r as! HTTPURLResponse).statusCode, d)
        }
        #expect(try await get("/live.m3u8").0 == 401)
        let (code, pl) = try await get("/live.m3u8?t=tok")
        #expect(code == 200)
        #expect(String(decoding: pl, as: UTF8.self).contains("seg0.ts?t=tok"))
        let (sc, seg) = try await get("/seg0.ts?t=tok")
        #expect(sc == 200 && seg.count % 188 == 0 && !seg.isEmpty)
        #expect(try await get("/?t=tok").0 == 200)
        server.stop()
    }

    /// Env-gated: writes real segments for ffprobe (GV_H264_FILE Annex-B with AUDs, GV_OUT_DIR).
    @Test func segmentsFromRealH264() throws {
        guard let file = ProcessInfo.processInfo.environment["GV_H264_FILE"],
              let dir = ProcessInfo.processInfo.environment["GV_OUT_DIR"] else { return }
        var s = HLSSegmenter()
        for (i, f) in try TestH264.accessUnits(path: file).enumerated() {
            s.push(avcc: f.avcc, isKeyframe: f.isKey, parameterSets: f.parameterSets, pts: Double(i) / 30)
        }
        for seg in s.window.segments { try seg.data.write(to: URL(fileURLWithPath: "\(dir)/real\(seg.seq).ts")) }
        try (s.window.playlist(token: "") ?? "").write(toFile: dir + "/real.m3u8", atomically: true, encoding: .utf8)
    }
}
