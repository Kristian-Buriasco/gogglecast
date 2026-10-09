import Foundation
import CryptoKit

/// Readable failures from the OBS connection.
enum OBSError: LocalizedError, Equatable {
    case unreachable
    case wrongPassword
    case passwordRequired
    case timeout
    case notConnected
    case connectionLost
    case requestFailed(code: Int, comment: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return L("Couldn't reach OBS. Is OBS running with WebSocket enabled (Tools > WebSocket Server Settings)?")
        case .wrongPassword: return L("Wrong WebSocket password")
        case .passwordRequired: return L("OBS needs a WebSocket password. Enter it here.")
        case .timeout: return L("OBS did not answer in time")
        case .notConnected: return L("Not connected to OBS")
        case .connectionLost: return L("The connection to OBS was lost")
        case .requestFailed(let code, let comment): return comment.isEmpty ? L("OBS refused the request (code %lld)", code) : L("OBS: %@", comment)
        case .badResponse(let s): return L("Unexpected answer from OBS: %@", s)
        }
    }
}

/// Tiny Equatable JSON value so decoded responses can be compared in tests.
enum JSONValue: Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
        default: self = .null
        }
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

/// A decoded obs-websocket v5 message.
enum OBSMessage: Equatable {
    struct Auth: Equatable { let challenge: String; let salt: String }
    struct Response: Equatable {
        let requestType: String
        let requestId: String
        let ok: Bool
        let code: Int
        let comment: String
        let data: [String: JSONValue]
    }
    case hello(rpcVersion: Int, auth: Auth?)
    case identified(rpcVersion: Int)
    case event(type: String)
    case response(Response)
    case other(op: Int)
}

/// Pure obs-websocket v5 helpers: auth computation, message encode and decode.
enum OBSProtocol {
    static let rpcVersion = 1
    static let authFailedCloseCode = 4009

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func base64SHA256(_ s: String) -> String { sha256(Data(s.utf8)).base64EncodedString() }

    /// base64(sha256(base64(sha256(password + salt)) + challenge))
    static func authentication(password: String, salt: String, challenge: String) -> String {
        base64SHA256(base64SHA256(password + salt) + challenge)
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func identify(authentication: String?) -> String {
        var d: [String: Any] = ["rpcVersion": rpcVersion]
        if let authentication { d["authentication"] = authentication }
        return json(["op": 1, "d": d])
    }

    static func request(type: String, id: String, data: [String: Any]? = nil) -> String {
        var d: [String: Any] = ["requestType": type, "requestId": id]
        if let data { d["requestData"] = data }
        return json(["op": 6, "d": d])
    }

    static func decode(_ text: String) -> OBSMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = obj["op"] as? Int else { return nil }
        let d = obj["d"] as? [String: Any] ?? [:]
        switch op {
        case 0:
            var auth: OBSMessage.Auth?
            if let a = d["authentication"] as? [String: Any],
               let c = a["challenge"] as? String, let s = a["salt"] as? String { auth = .init(challenge: c, salt: s) }
            return .hello(rpcVersion: d["rpcVersion"] as? Int ?? 0, auth: auth)
        case 2:
            return .identified(rpcVersion: d["negotiatedRpcVersion"] as? Int ?? 0)
        case 5:
            return .event(type: d["eventType"] as? String ?? "")
        case 7:
            guard let type = d["requestType"] as? String, let id = d["requestId"] as? String else { return nil }
            let st = d["requestStatus"] as? [String: Any] ?? [:]
            let data = (d["responseData"] as? [String: Any]).map { $0.mapValues(JSONValue.init) } ?? [:]
            return .response(.init(requestType: type, requestId: id, ok: st["result"] as? Bool ?? false,
                                   code: st["code"] as? Int ?? 0, comment: st["comment"] as? String ?? "", data: data))
        default:
            return .other(op: op)
        }
    }

    /// "ws://host:port" for a user-typed host (IPv6 literals get brackets). Nil for an unusable host.
    static func url(host: String, port: Int) -> URL? {
        var h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, (1...65535).contains(port), !h.contains("/"), !h.contains(" ") else { return nil }
        if h.contains(":") && !h.hasPrefix("[") { h = "[\(h)]" }
        return URL(string: "ws://\(h):\(port)")
    }
}

struct OBSVersion: Equatable {
    let obsVersion: String
    let webSocketVersion: String
}

/// Minimal obs-websocket v5 client on URLSessionWebSocketTask. Only talks to the host it is given.
actor OBSClient {
    static let handshakeTimeout: TimeInterval = 5
    static let requestTimeout: TimeInterval = 5

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<OBSMessage.Response, Error>] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isConnected = false

    init() {}

    // MARK: Connection

    func connect(host: String, port: Int, password: String) async throws {
        disconnect()
        guard let url = OBSProtocol.url(host: host, port: port) else { throw OBSError.unreachable }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        do {
            try await handshake(task: task, password: password)
        } catch {
            teardown()
            throw error
        }
        isConnected = true
        receiveTask = Task { [weak self] in await self?.receiveLoop(task: task) }
    }

    func disconnect() {
        teardown()
    }

    /// Returns when the connection is closed (immediately if there is none).
    func waitUntilClosed() async {
        guard isConnected else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func teardown() {
        isConnected = false
        receiveTask?.cancel(); receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
        let p = pending; pending = [:]
        for (_, c) in p { c.resume(throwing: OBSError.connectionLost) }
        let w = closeWaiters; closeWaiters = []
        for c in w { c.resume() }
    }

    private func handshake(task: URLSessionWebSocketTask, password: String) async throws {
        let hello: OBSMessage
        do {
            hello = try await receiveMessage(task: task, timeout: Self.handshakeTimeout)
        } catch {
            throw OBSError.unreachable
        }
        guard case .hello(_, let auth) = hello else { throw OBSError.badResponse("expected Hello") }
        var authString: String?
        if let auth {
            guard !password.isEmpty else { throw OBSError.passwordRequired }
            authString = OBSProtocol.authentication(password: password, salt: auth.salt, challenge: auth.challenge)
        }
        do {
            try await task.send(.string(OBSProtocol.identify(authentication: authString)))
        } catch {
            throw OBSError.unreachable
        }
        do {
            let reply = try await receiveMessage(task: task, timeout: Self.handshakeTimeout)
            guard case .identified = reply else { throw OBSError.badResponse("expected Identified") }
        } catch let e as OBSError {
            throw e
        } catch {
            // OBS closes with 4009 when the password is wrong.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if task.closeCode.rawValue == OBSProtocol.authFailedCloseCode { throw OBSError.wrongPassword }
            throw auth != nil ? OBSError.wrongPassword : OBSError.connectionLost
        }
    }

    /// Receive one text message; on timeout the socket is cancelled so the receive returns.
    private func receiveMessage(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> OBSMessage {
        let flag = TimeoutFlag()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { flag.fire(); task.cancel(with: .goingAway, reason: nil) }
        }
        defer { timer.cancel() }
        do {
            while true {
                let m = try await task.receive()
                if case .string(let s) = m, let msg = OBSProtocol.decode(s) { return msg }
            }
        } catch {
            if flag.fired { throw OBSError.timeout }
            throw error
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let m = try await task.receive()
                if case .string(let s) = m, let msg = OBSProtocol.decode(s), case .response(let r) = msg,
                   let c = pending.removeValue(forKey: r.requestId) {
                    c.resume(returning: r)
                }
            } catch {
                break
            }
        }
        if self.task === task { teardown() }
    }

    // MARK: Requests

    func request(_ type: String, data: [String: Any]? = nil) async throws -> [String: JSONValue] {
        guard isConnected, let task else { throw OBSError.notConnected }
        let id = UUID().uuidString
        let text = OBSProtocol.request(type: type, id: id, data: data)
        let response: OBSMessage.Response = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                await self?.expire(id)
            }
            task.send(.string(text)) { [weak self] err in
                if err != nil { Task { await self?.fail(id, OBSError.connectionLost) } }
            }
        }
        guard response.ok else { throw OBSError.requestFailed(code: response.code, comment: response.comment) }
        return response.data
    }

    private func expire(_ id: String) { fail(id, OBSError.timeout) }
    private func fail(_ id: String, _ error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }

    // MARK: API

    func getVersion() async throws -> OBSVersion {
        let d = try await request("GetVersion")
        return OBSVersion(obsVersion: d["obsVersion"]?.string ?? "unknown",
                          webSocketVersion: d["obsWebSocketVersion"]?.string ?? "unknown")
    }

    func getSceneList() async throws -> [String] {
        let d = try await request("GetSceneList")
        return (d["scenes"]?.array ?? []).compactMap { $0.object?["sceneName"]?.string }
    }

    func getCurrentProgramScene() async throws -> String {
        let d = try await request("GetCurrentProgramScene")
        guard let n = d["currentProgramSceneName"]?.string ?? d["sceneName"]?.string else { throw OBSError.badResponse("no scene name") }
        return n
    }

    func setCurrentProgramScene(_ name: String) async throws {
        _ = try await request("SetCurrentProgramScene", data: ["sceneName": name])
    }

    /// Names of the inputs of one kind (for example "ffmpeg_source").
    func getInputNames(kind: String) async throws -> [String] {
        let d = try await request("GetInputList", data: ["inputKind": kind])
        return (d["inputs"]?.array ?? []).compactMap { $0.object?["inputName"]?.string }
    }

    func createInput(scene: String, name: String, kind: String, settings: [String: Any]) async throws {
        _ = try await request("CreateInput", data: ["sceneName": scene, "inputName": name, "inputKind": kind,
                                                    "inputSettings": settings, "sceneItemEnabled": true])
    }

    func setInputSettings(name: String, settings: [String: Any]) async throws {
        _ = try await request("SetInputSettings", data: ["inputName": name, "inputSettings": settings, "overlay": true])
    }

    func startRecord() async throws { _ = try await request("StartRecord") }
    func stopRecord() async throws { _ = try await request("StopRecord") }

    func getRecordStatus() async throws -> Bool {
        let d = try await request("GetRecordStatus")
        return d["outputActive"]?.bool ?? false
    }

    func startStream() async throws { _ = try await request("StartStream") }
    func stopStream() async throws { _ = try await request("StopStream") }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    func fire() { lock.lock(); _fired = true; lock.unlock() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
}
