import XCTest
import Network
@testable import GogglesView

// MARK: Protocol (pure)

final class OBSProtocolTests: XCTestCase {
    func testSHA256AndBase64StepsSeparately() {
        XCTAssertEqual(OBSProtocol.sha256(Data()).map { String(format: "%02x", $0) }.joined(),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(OBSProtocol.base64SHA256("abc"), "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
    }

    /// Pinned vector computed independently (Python hashlib) from the documented algorithm.
    func testPinnedAuthVector() {
        XCTAssertEqual(OBSProtocol.base64SHA256("supersecretpassword" + "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="),
                       "H1IfVz1pSREUQzbFTVnX/Tyb+gMhMik5x7yUBCY0PTs=")
        let auth = OBSProtocol.authentication(
            password: "supersecretpassword",
            salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
            challenge: "+IxH4CnCiqpX1rZ1l/hFsTqCBU7ZxCSHxOu0lEg0YpU=")
        XCTAssertEqual(auth, "o4WjBmh71QuEO8cweD1N2LNyNdxjRHcDRKuSSYiDyL8=")
    }

    func testAuthIsTwoStep() {
        let secret = OBSProtocol.base64SHA256("pw" + "salt")
        XCTAssertEqual(OBSProtocol.authentication(password: "pw", salt: "salt", challenge: "ch"),
                       OBSProtocol.base64SHA256(secret + "ch"))
    }

    func testIdentifyEncoding() throws {
        let plain = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(OBSProtocol.identify(authentication: nil).utf8)) as? [String: Any])
        XCTAssertEqual(plain["op"] as? Int, 1)
        let d = try XCTUnwrap(plain["d"] as? [String: Any])
        XCTAssertEqual(d["rpcVersion"] as? Int, 1)
        XCTAssertNil(d["authentication"])
        let withAuth = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(OBSProtocol.identify(authentication: "xyz").utf8)) as? [String: Any])
        XCTAssertEqual((withAuth["d"] as? [String: Any])?["authentication"] as? String, "xyz")
    }

    func testRequestEncoding() throws {
        let s = OBSProtocol.request(type: "SetCurrentProgramScene", id: "abc", data: ["sceneName": "Game"])
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        XCTAssertEqual(o["op"] as? Int, 6)
        let d = try XCTUnwrap(o["d"] as? [String: Any])
        XCTAssertEqual(d["requestType"] as? String, "SetCurrentProgramScene")
        XCTAssertEqual(d["requestId"] as? String, "abc")
        XCTAssertEqual((d["requestData"] as? [String: Any])?["sceneName"] as? String, "Game")
    }

    func testDecodeHello() {
        let plain = #"{"op":0,"d":{"obsWebSocketVersion":"5.5.0","rpcVersion":1}}"#
        XCTAssertEqual(OBSProtocol.decode(plain), .hello(rpcVersion: 1, auth: nil))
        let auth = #"{"op":0,"d":{"rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}"#
        XCTAssertEqual(OBSProtocol.decode(auth), .hello(rpcVersion: 1, auth: .init(challenge: "c", salt: "s")))
    }

    func testDecodeIdentifiedEventAndResponse() {
        XCTAssertEqual(OBSProtocol.decode(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#), .identified(rpcVersion: 1))
        XCTAssertEqual(OBSProtocol.decode(#"{"op":5,"d":{"eventType":"CurrentProgramSceneChanged","eventIntent":4}}"#),
                       .event(type: "CurrentProgramSceneChanged"))
        let r = OBSProtocol.decode(#"{"op":7,"d":{"requestType":"GetRecordStatus","requestId":"1","requestStatus":{"result":true,"code":100},"responseData":{"outputActive":false}}}"#)
        guard case .response(let resp)? = r else { return XCTFail("not a response") }
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.data["outputActive"], .bool(false))
        let bad = OBSProtocol.decode(#"{"op":7,"d":{"requestType":"X","requestId":"2","requestStatus":{"result":false,"code":600,"comment":"nope"}}}"#)
        guard case .response(let b)? = bad else { return XCTFail("not a response") }
        XCTAssertFalse(b.ok)
        XCTAssertEqual(b.comment, "nope")
    }

    func testDecodeGarbage() {
        XCTAssertNil(OBSProtocol.decode("not json"))
        XCTAssertNil(OBSProtocol.decode(#"{"nop":1}"#))
        XCTAssertEqual(OBSProtocol.decode(#"{"op":9,"d":{}}"#), .other(op: 9))
    }

    func testURLBuilding() {
        XCTAssertEqual(OBSProtocol.url(host: "127.0.0.1", port: 4455)?.absoluteString, "ws://127.0.0.1:4455")
        XCTAssertEqual(OBSProtocol.url(host: " pc.local ", port: 1)?.absoluteString, "ws://pc.local:1")
        XCTAssertEqual(OBSProtocol.url(host: "::1", port: 4455)?.absoluteString, "ws://[::1]:4455")
        XCTAssertNil(OBSProtocol.url(host: "", port: 4455))
        XCTAssertNil(OBSProtocol.url(host: "a/b", port: 4455))
        XCTAssertNil(OBSProtocol.url(host: "x", port: 0))
    }

    func testErrorsAreReadable() {
        XCTAssertEqual(OBSError.wrongPassword.errorDescription, "Wrong WebSocket password")
        XCTAssertTrue(OBSError.unreachable.errorDescription?.contains("Tools > WebSocket Server Settings") == true)
    }
}

// MARK: Rule engine (pure)

final class OBSRuleEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private var record: OBSRules { OBSRules(recordWithStream: true, graceSeconds: 30) }

    func testAllRulesOffDoNothing() {
        var e = OBSRuleEngine()
        let r = OBSRules()
        XCTAssertFalse(r.recordWithStream || r.switchScenes || r.stopWithMyRecording)
        XCTAssertEqual(e.handle(.streamLive, rules: r, at: t0), [])
        XCTAssertEqual(e.handle(.streamLost, rules: r, at: at(1)), [])
        XCTAssertEqual(e.handle(.tick, rules: r, at: at(100)), [])
        XCTAssertEqual(e.handle(.sessionDisconnected, rules: r, at: at(101)), [])
        XCTAssertEqual(e.handle(.userRecordingStopped, rules: r, at: at(102)), [])
    }

    func testLiveStartsRecordingOnce() {
        var e = OBSRuleEngine()
        XCTAssertEqual(e.handle(.streamLive, rules: record, at: t0), [.startRecord])
        XCTAssertEqual(e.handle(.streamLive, rules: record, at: at(1)), [])
    }

    func testStopsOnlyAfterGrace() {
        var e = OBSRuleEngine()
        _ = e.handle(.streamLive, rules: record, at: t0)
        XCTAssertEqual(e.handle(.streamLost, rules: record, at: at(10)), [])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(39.9)), [])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(40)), [.stopRecord])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(50)), [])
        XCTAssertFalse(e.ownsRecording)
    }

    func testComingBackWithinGraceKeepsRecording() {
        var e = OBSRuleEngine()
        _ = e.handle(.streamLive, rules: record, at: t0)
        _ = e.handle(.streamLost, rules: record, at: at(10))
        XCTAssertEqual(e.handle(.streamLive, rules: record, at: at(20)), [])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(200)), [])
        XCTAssertTrue(e.ownsRecording)
    }

    func testGraceRestartsOnSecondLoss() {
        var e = OBSRuleEngine()
        _ = e.handle(.streamLive, rules: record, at: t0)
        _ = e.handle(.streamLost, rules: record, at: at(10))
        _ = e.handle(.streamLive, rules: record, at: at(20))
        _ = e.handle(.streamLost, rules: record, at: at(100))
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(120)), [])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(130)), [.stopRecord])
    }

    func testDisconnectStopsImmediately() {
        var e = OBSRuleEngine()
        _ = e.handle(.streamLive, rules: record, at: t0)
        XCTAssertEqual(e.handle(.sessionDisconnected, rules: record, at: at(5)), [.stopRecord])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(500)), [])
    }

    func testNeverStopsARecordingItDidNotStart() {
        var e = OBSRuleEngine()
        // Lost without ever being live, or while the engine does not own a recording.
        XCTAssertEqual(e.handle(.streamLost, rules: record, at: t0), [])
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(100)), [])
        XCTAssertEqual(e.handle(.sessionDisconnected, rules: record, at: at(101)), [])
        _ = e.handle(.streamLive, rules: record, at: at(102))
        e.recordingNotOwned()  // OBS was already recording
        _ = e.handle(.streamLost, rules: record, at: at(103))
        XCTAssertEqual(e.handle(.tick, rules: record, at: at(500)), [])
    }

    func testFailedStartCanRetryOnNextLive() {
        var e = OBSRuleEngine()
        XCTAssertEqual(e.handle(.streamLive, rules: record, at: t0), [.startRecord])
        e.recordingNotOwned()
        XCTAssertEqual(e.handle(.streamLive, rules: record, at: at(1)), [.startRecord])
    }

    func testSceneSwitching() {
        var e = OBSRuleEngine()
        let r = OBSRules(switchScenes: true, liveScene: "Game", lostScene: "Be right back")
        XCTAssertEqual(e.handle(.streamLive, rules: r, at: t0), [.setScene("Game")])
        XCTAssertEqual(e.handle(.streamLost, rules: r, at: at(1)), [.setScene("Be right back")])
        let onlyLive = OBSRules(switchScenes: true, liveScene: "Game", lostScene: "")
        XCTAssertEqual(e.handle(.streamLost, rules: onlyLive, at: at(2)), [])
        let off = OBSRules(switchScenes: false, liveScene: "Game", lostScene: "BRB")
        XCTAssertEqual(e.handle(.streamLive, rules: off, at: at(3)), [])
    }

    func testStopWithMyRecording() {
        var e = OBSRuleEngine()
        let on = OBSRules(recordWithStream: true, stopWithMyRecording: true)
        _ = e.handle(.streamLive, rules: on, at: t0)
        XCTAssertEqual(e.handle(.userRecordingStopped, rules: on, at: at(5)), [.stopRecord])
        // Rule off: nothing, and it forgets the recording so it will not stop it later.
        var f = OBSRuleEngine()
        _ = f.handle(.streamLive, rules: record, at: t0)
        XCTAssertEqual(f.handle(.userRecordingStopped, rules: record, at: at(5)), [])
        XCTAssertEqual(f.handle(.sessionDisconnected, rules: record, at: at(6)), [])
        // Nothing started by us: nothing to stop.
        var g = OBSRuleEngine()
        XCTAssertEqual(g.handle(.userRecordingStopped, rules: on, at: t0), [])
    }

    func testRuleDisabledMidGraceCancelsStop() {
        var e = OBSRuleEngine()
        _ = e.handle(.streamLive, rules: record, at: t0)
        _ = e.handle(.streamLost, rules: record, at: at(1))
        XCTAssertEqual(e.handle(.tick, rules: OBSRules(), at: at(100)), [])
        XCTAssertFalse(e.isWaitingOutGrace)
    }

    func testDebouncedFlappingProducesNoActions() {
        var deb = StreamEventDebouncer(stableFor: 3)
        var e = OBSRuleEngine()
        var actions: [OBSAction] = []
        func step(_ kind: GogglesUIStateKind, _ s: TimeInterval) {
            deb.observe(kind, at: at(s))
            if let ev = deb.tick(at: at(s)) {
                actions += e.handle(ev == .streamLive ? .streamLive : .streamLost, rules: record, at: at(s))
            }
        }
        step(.live, 0); step(.stalled, 1); step(.live, 2); step(.stalled, 3); step(.live, 4)
        XCTAssertEqual(actions, [])
        step(.live, 8)  // steady for 4 s now
        XCTAssertEqual(actions, [.startRecord])
    }

    func testLiveTrackerCombinesWindows() {
        var t = OBSLiveTracker()
        XCTAssertEqual(t.update(deviceId: "a", live: true), .streamLive)
        XCTAssertNil(t.update(deviceId: "b", live: true))
        XCTAssertNil(t.update(deviceId: "a", live: false))
        XCTAssertEqual(t.update(deviceId: "b", live: false), .streamLost)
        XCTAssertNil(t.update(deviceId: "b", live: false))
    }
}

// MARK: Whole handshake against a local WebSocket server

/// A tiny obs-websocket v5 server on a free loopback port.
final class FakeOBSServer {
    let password: String?
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-obs")
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _scene = "Gameplay"
    private var _recording = false

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var scene: String { lock.lock(); defer { lock.unlock() }; return _scene }
    var recording: Bool { lock.lock(); defer { lock.unlock() }; return _recording }

    init(password: String?) throws {
        self.password = password
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port else { throw OBSError.unreachable }
        port = p.rawValue
    }

    func stop() { listener.cancel() }

    private func send(_ conn: NWConnection, _ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func close(_ conn: NWConnection, code: UInt16) {
        let md = NWProtocolWebSocket.Metadata(opcode: .close)
        md.closeCode = .applicationCode(code)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [md])
        conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private var salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
    private var challenge = "+IxH4CnCiqpX1rZ1l/hFsTqCBU7ZxCSHxOu0lEg0YpU="

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        var d: [String: Any] = ["obsWebSocketVersion": "5.5.0", "rpcVersion": 1]
        if password != nil { d["authentication"] = ["challenge": challenge, "salt": salt] }
        send(conn, ["op": 0, "d": d])
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            self.handle(conn, text)
            self.receive(conn)
        }
    }

    private func handle(_ conn: NWConnection, _ text: String) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = o["op"] as? Int, let d = o["d"] as? [String: Any] else { return }
        if op == 1 {
            if let password {
                let expected = OBSProtocol.authentication(password: password, salt: salt, challenge: challenge)
                guard d["authentication"] as? String == expected else { close(conn, code: 4009); return }
            }
            send(conn, ["op": 2, "d": ["negotiatedRpcVersion": 1]])
            return
        }
        guard op == 6, let type = d["requestType"] as? String, let id = d["requestId"] as? String else { return }
        let rd = d["requestData"] as? [String: Any] ?? [:]
        lock.lock(); _requests.append(type)
        var data: [String: Any] = [:]
        var ok = true
        var code = 100
        var comment = ""
        switch type {
        case "GetVersion": data = ["obsVersion": "30.2.3", "obsWebSocketVersion": "5.5.0"]
        case "GetSceneList": data = ["scenes": [["sceneName": "BRB", "sceneIndex": 0], ["sceneName": "Gameplay", "sceneIndex": 1]]]
        case "GetCurrentProgramScene": data = ["currentProgramSceneName": _scene]
        case "SetCurrentProgramScene": _scene = rd["sceneName"] as? String ?? _scene
        case "StartRecord": _recording = true
        case "StopRecord": _recording = false
        case "GetRecordStatus": data = ["outputActive": _recording]
        case "StartStream", "StopStream": break
        default: ok = false; code = 204; comment = "Unknown request type"
        }
        lock.unlock()
        send(conn, ["op": 7, "d": ["requestType": type, "requestId": id,
                                   "requestStatus": ["result": ok, "code": code, "comment": comment],
                                   "responseData": data]])
    }
}

final class OBSClientHandshakeTests: XCTestCase {
    func testConnectWithoutPasswordAndRunRequests() async throws {
        let server = try FakeOBSServer(password: nil)
        defer { server.stop() }
        let client = OBSClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), password: "")
        let v = try await client.getVersion()
        XCTAssertEqual(v, OBSVersion(obsVersion: "30.2.3", webSocketVersion: "5.5.0"))
        let scenes = try await client.getSceneList()
        XCTAssertEqual(scenes, ["BRB", "Gameplay"])
        let current = try await client.getCurrentProgramScene()
        XCTAssertEqual(current, "Gameplay")
        try await client.setCurrentProgramScene("BRB")
        XCTAssertEqual(server.scene, "BRB")
        var active = try await client.getRecordStatus()
        XCTAssertFalse(active)
        try await client.startRecord()
        XCTAssertTrue(server.recording)
        active = try await client.getRecordStatus()
        XCTAssertTrue(active)
        try await client.stopRecord()
        XCTAssertFalse(server.recording)
        try await client.startStream()
        try await client.stopStream()
        XCTAssertEqual(server.requests.suffix(2), ["StartStream", "StopStream"])
        await client.disconnect()
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testAuthenticatedHandshake() async throws {
        let server = try FakeOBSServer(password: "supersecretpassword")
        defer { server.stop() }
        let client = OBSClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), password: "supersecretpassword")
        let v = try await client.getVersion()
        XCTAssertEqual(v.obsVersion, "30.2.3")
        await client.disconnect()
    }

    func testWrongPassword() async throws {
        let server = try FakeOBSServer(password: "right")
        defer { server.stop() }
        let client = OBSClient()
        do {
            try await client.connect(host: "127.0.0.1", port: Int(server.port), password: "wrong")
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? OBSError, .wrongPassword)
        }
    }

    func testPasswordRequiredWhenEmpty() async throws {
        let server = try FakeOBSServer(password: "right")
        defer { server.stop() }
        let client = OBSClient()
        do {
            try await client.connect(host: "127.0.0.1", port: Int(server.port), password: "")
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? OBSError, .passwordRequired)
        }
    }

    func testUnreachable() async throws {
        let server = try FakeOBSServer(password: nil)
        let port = Int(server.port)
        server.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let client = OBSClient()
        do {
            try await client.connect(host: "127.0.0.1", port: port, password: "")
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? OBSError, .unreachable)
        }
    }

    func testRequestWithoutConnectionFails() async {
        let client = OBSClient()
        do {
            _ = try await client.getVersion()
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? OBSError, .notConnected)
        }
    }

    func testUnknownRequestSurfacesOBSMessage() async throws {
        let server = try FakeOBSServer(password: nil)
        defer { server.stop() }
        let client = OBSClient()
        try await client.connect(host: "127.0.0.1", port: Int(server.port), password: "")
        do {
            _ = try await client.request("Bogus")
            XCTFail("should have failed")
        } catch {
            XCTAssertEqual(error as? OBSError, .requestFailed(code: 204, comment: "Unknown request type"))
        }
        await client.disconnect()
    }

    func testTestConnectionHelper() async throws {
        let server = try FakeOBSServer(password: nil)
        defer { server.stop() }
        let ok = await OBSIntegration.testConnection(host: "127.0.0.1", port: Int(server.port), password: "")
        XCTAssertEqual(try ok.get().obsVersion, "30.2.3")
    }
}
