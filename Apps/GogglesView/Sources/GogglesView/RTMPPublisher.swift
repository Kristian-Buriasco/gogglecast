import Foundation
import CoreMedia
import Network

enum RTMPPrefs {
    static let urlKey = "rtmpURL"
    static let streamKeyKey = "rtmpStreamKey" // secret: UserDefaults for now, never logged
    static let autoStartKey = "rtmpAutoStart"
    static var url: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var streamKey: String { UserDefaults.standard.string(forKey: streamKeyKey) ?? "" }
}

// MARK: - Pure protocol pieces

enum AMF0 {
    indirect enum Value: Equatable {
        case number(Double), bool(Bool), string(String), null, undefined
        case object([Pair]), ecmaArray([Pair])
        var number: Double? { if case .number(let n) = self { return n }; return nil }
        var string: String? { if case .string(let s) = self { return s }; return nil }
        var properties: [Pair]? {
            switch self { case .object(let p), .ecmaArray(let p): return p; default: return nil }
        }
    }
    struct Pair: Equatable {
        let key: String, value: Value
        init(_ k: String, _ v: Value) { key = k; value = v }
    }

    static func encode(_ values: [Value]) -> [UInt8] { values.flatMap(encode) }

    static func encode(_ v: Value) -> [UInt8] {
        switch v {
        case .number(let n): return [0x00] + be64(n.bitPattern)
        case .bool(let b): return [0x01, b ? 1 : 0]
        case .string(let s): return [0x02] + utf8(s)
        case .null: return [0x05]
        case .undefined: return [0x06]
        case .object(let p): return [0x03] + props(p) + [0, 0, 0x09]
        case .ecmaArray(let p):
            let n = UInt32(p.count)
            return [0x08] + RTMPChunk.be32(n) + props(p) + [0, 0, 0x09]
        }
    }

    private static func props(_ p: [Pair]) -> [UInt8] { p.flatMap { utf8($0.key) + encode($0.value) } }
    private static func utf8(_ s: String) -> [UInt8] {
        let b = Array(s.utf8.prefix(0xFFFF))
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }
    private static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> UInt64(56 - 8 * $0) & 0xFF) } }

    /// Decodes consecutive values; stops (returning what it has) on malformed/unsupported input.
    static func decode(_ b: [UInt8]) -> [Value] {
        var i = 0
        var out: [Value] = []
        while i < b.count, let v = decodeValue(b, &i) { out.append(v) }
        return out
    }

    private static func decodeValue(_ b: [UInt8], _ i: inout Int) -> Value? {
        guard i < b.count else { return nil }
        let t = b[i]; i += 1
        switch t {
        case 0x00:
            guard i + 8 <= b.count else { return nil }
            let bits = b[i..<i + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            i += 8; return .number(Double(bitPattern: bits))
        case 0x01:
            guard i < b.count else { return nil }
            i += 1; return .bool(b[i - 1] != 0)
        case 0x02: return readString(b, &i, long: false).map(Value.string)
        case 0x0C: return readString(b, &i, long: true).map(Value.string)
        case 0x05: return .null
        case 0x06: return .undefined
        case 0x03: return readProps(b, &i).map(Value.object)
        case 0x08:
            guard i + 4 <= b.count else { return nil }
            i += 4; return readProps(b, &i).map(Value.ecmaArray)
        default: return nil
        }
    }

    private static func readString(_ b: [UInt8], _ i: inout Int, long: Bool) -> String? {
        let hdr = long ? 4 : 2
        guard i + hdr <= b.count else { return nil }
        let n = b[i..<i + hdr].reduce(0) { $0 << 8 | Int($1) }
        i += hdr
        guard i + n <= b.count else { return nil }
        defer { i += n }
        return String(decoding: b[i..<i + n], as: UTF8.self)
    }

    private static func readProps(_ b: [UInt8], _ i: inout Int) -> [Pair]? {
        var out: [Pair] = []
        while true {
            guard i + 3 <= b.count else { return nil }
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 0x09 { i += 3; return out }
            guard let k = readString(b, &i, long: false), let v = decodeValue(b, &i) else { return nil }
            out.append(Pair(k, v))
        }
    }
}

enum RTMPChunk {
    struct Message: Equatable {
        var typeID: UInt8, streamID: UInt32, timestamp: UInt32, payload: [UInt8]
    }

    /// Splits one message into chunks: a fmt-0 header then fmt-3 continuations.
    static func encode(csid: UInt8, typeID: UInt8, streamID: UInt32, timestamp: UInt32,
                       payload: [UInt8], chunkSize: Int) -> [UInt8] {
        let ext = timestamp >= 0xFF_FFFF
        let tsField = ext ? 0xFF_FFFF : timestamp
        let extBytes: [UInt8] = ext ? be32(timestamp) : []
        let len = payload.count
        var out: [UInt8] = [csid & 0x3F,
                            UInt8(tsField >> 16 & 0xFF), UInt8(tsField >> 8 & 0xFF), UInt8(tsField & 0xFF),
                            UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF),
                            typeID,
                            UInt8(streamID & 0xFF), UInt8(streamID >> 8 & 0xFF), UInt8(streamID >> 16 & 0xFF), UInt8(streamID >> 24 & 0xFF)]
        out += extBytes
        out.reserveCapacity(len + len / chunkSize * 5 + 20)
        var off = 0
        while true {
            let n = min(chunkSize, len - off)
            out += payload[off..<off + n]
            off += n
            if off >= len { break }
            out.append(0xC0 | (csid & 0x3F))
            out += extBytes
        }
        return out
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// Incremental de-chunker for server->client traffic. Honors peer Set Chunk Size itself.
    struct Reader {
        private struct State {
            var ts: UInt32 = 0, delta: UInt32 = 0, len = 0, type: UInt8 = 0, sid: UInt32 = 0
            var buf: [UInt8] = []
            var ext = false
        }
        private var buffer: [UInt8] = []
        private var streams: [UInt32: State] = [:]
        private(set) var chunkSize = 128
        init() {}

        mutating func feed(_ d: [UInt8]) -> [Message] {
            buffer += d
            var out: [Message] = []
            while let step = parseOne() { if let m = step { out.append(m) } }
            return out
        }

        /// nil = need more bytes; .some(nil) = chunk consumed, message incomplete.
        private mutating func parseOne() -> Message?? {
            let b = buffer
            var i = 0
            func need(_ n: Int) -> Bool { i + n <= b.count }
            guard need(1) else { return nil }
            let fmt = b[0] >> 6
            var csid = UInt32(b[0] & 0x3F)
            i = 1
            if csid == 0 { guard need(1) else { return nil }; csid = UInt32(b[1]) + 64; i = 2 }
            else if csid == 1 { guard need(2) else { return nil }; csid = UInt32(b[2]) << 8 + UInt32(b[1]) + 64; i = 3 }
            var st = streams[csid] ?? State()
            let hdr = [11, 7, 3, 0][Int(fmt)]
            guard need(hdr) else { return nil }
            var tsField: UInt32 = 0
            if fmt <= 2 { tsField = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) }
            if fmt <= 1 {
                st.len = Int(b[i + 3]) << 16 | Int(b[i + 4]) << 8 | Int(b[i + 5])
                st.type = b[i + 6]
            }
            if fmt == 0 { st.sid = UInt32(b[i + 7]) | UInt32(b[i + 8]) << 8 | UInt32(b[i + 9]) << 16 | UInt32(b[i + 10]) << 24 }
            i += hdr
            if fmt <= 2 { st.ext = tsField == 0xFF_FFFF }
            if st.ext {
                guard need(4) else { return nil }
                tsField = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                i += 4
            }
            let take = min(chunkSize, st.len - st.buf.count)
            guard need(take) else { return nil }
            if st.buf.isEmpty { // first chunk of a message sets the timestamp
                if fmt == 0 { st.ts = tsField; st.delta = 0 }
                else if fmt <= 2 { st.delta = tsField; st.ts &+= tsField }
                else { st.ts &+= st.delta }
            }
            st.buf += b[i..<i + take]
            i += take
            buffer.removeFirst(i)
            if st.buf.count < st.len { streams[csid] = st; return .some(nil) }
            let msg = Message(typeID: st.type, streamID: st.sid, timestamp: st.ts, payload: st.buf)
            st.buf = []
            streams[csid] = st
            if msg.typeID == 1, msg.payload.count >= 4 {
                chunkSize = max(1, Int(msg.payload[0] & 0x7F) << 24 | Int(msg.payload[1]) << 16 | Int(msg.payload[2]) << 8 | Int(msg.payload[3]))
            }
            return .some(msg)
        }
    }
}

enum RTMPFLV {
    /// AVCDecoderConfigurationRecord (ISO 14496-15) with 4-byte NAL lengths.
    static func avcDecoderConfigurationRecord(sps: [Data], pps: [Data]) -> [UInt8]? {
        guard let first = sps.first, first.count >= 4, !pps.isEmpty, sps.count < 32, pps.count < 256 else { return nil }
        let s = [UInt8](first)
        var r: [UInt8] = [1, s[1], s[2], s[3], 0xFF, 0xE0 | UInt8(sps.count)]
        for x in sps { r += [UInt8(x.count >> 8), UInt8(x.count & 0xFF)] + x }
        r.append(UInt8(pps.count))
        for x in pps { r += [UInt8(x.count >> 8), UInt8(x.count & 0xFF)] + x }
        return r
    }

    /// RTMP video message body for AVC (codec id 7): frame/codec byte, packet type, 24-bit composition time.
    static func videoTag(keyframe: Bool, sequenceHeader: Bool, compositionTime: Int32 = 0, data: [UInt8]) -> [UInt8] {
        let ct = UInt32(bitPattern: compositionTime)
        return [(keyframe ? 0x10 : 0x20) | 7, sequenceHeader ? 0 : 1,
                UInt8(ct >> 16 & 0xFF), UInt8(ct >> 8 & 0xFF), UInt8(ct & 0xFF)] + data
    }

    static func onMetaData(width: Int, height: Int, fps: Double) -> [UInt8] {
        AMF0.encode([.string("@setDataFrame"), .string("onMetaData"),
                     .ecmaArray([AMF0.Pair("width", .number(Double(width))), AMF0.Pair("height", .number(Double(height))),
                                 AMF0.Pair("framerate", .number(fps)), AMF0.Pair("videocodecid", .number(7)),
                                 AMF0.Pair("duration", .number(0))])])
    }
}

struct RTMPTarget: Equatable {
    var secure: Bool, host: String, port: Int, app: String
    var tcURL: String { "\(secure ? "rtmps" : "rtmp")://\(host)\(port == (secure ? 443 : 1935) ? "" : ":\(port)")/\(app)" }

    static func parse(_ s: String) -> RTMPTarget? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps",
              let host = c.host, !host.isEmpty else { return nil }
        let secure = scheme == "rtmps"
        var app = c.path
        if app.hasPrefix("/") { app.removeFirst() }
        if let q = c.query { app += "?" + q }
        guard !app.isEmpty else { return nil }
        return RTMPTarget(secure: secure, host: host, port: c.port ?? (secure ? 443 : 1935), app: app)
    }
}

func redactStreamKey(_ text: String, key: String) -> String {
    key.isEmpty ? text : text.replacingOccurrences(of: key, with: "***")
}

// MARK: - Publisher

/// Minimal RTMP publisher (consumer of passthrough H.264). Everything runs on one
/// private queue; `enqueue` only hops to it. TCP backlog is bounded: on overflow
/// frames are dropped until the next keyframe so the receiver never sees a broken GOP.
final class RTMPPublisher: ObservableObject, SampleBufferRendering {
    @Published private(set) var isStreaming = false
    @Published private(set) var isLive = false
    @Published private(set) var status = "Idle"
    @Published private(set) var lastError: String?
    @Published private(set) var bytesSent: UInt64 = 0

    private enum Phase { case idle, handshake, connecting, creating, publishing }

    private static let chunkSize = 4096
    private static let maxBacklog = 3_000_000

    private let queue = DispatchQueue(label: "RTMPPublisher")
    private var conn: NWConnection?
    private var phase = Phase.idle
    private var target: RTMPTarget?
    private var streamKey = ""
    private var rx: [UInt8] = []
    private var reader = RTMPChunk.Reader()
    private var streamID: UInt32 = 0
    private var backlog = 0
    private var sentTotal: UInt64 = 0
    private var needsKey = true
    private var sentParams: [Data] = []
    private var sentMeta = false
    private var baseTime: Double?
    private var received = 0, lastAck = 0, windowSize = 2_500_000

    func start(url: String, streamKey: String) {
        queue.async { [self] in
            stopLocked()
            guard let t = RTMPTarget.parse(url), let port = NWEndpoint.Port(rawValue: UInt16(clamping: t.port)) else {
                setStatus("Idle", error: "Invalid RTMP URL (expected rtmp://host/app)"); return
            }
            guard !streamKey.isEmpty else { setStatus("Idle", error: "Stream key is empty"); return }
            target = t; self.streamKey = streamKey
            let c = NWConnection(host: NWEndpoint.Host(t.host), port: port, using: t.secure ? .tls : .tcp)
            conn = c
            phase = .handshake
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let self, let c else { return }
                self.queue.async {
                    guard c === self.conn else { return }
                    switch st {
                    case .ready: self.sendHandshake(c)
                    case .failed(let e): self.fail(e.localizedDescription)
                    case .waiting(let e): self.setStatus("Connecting", error: self.redact(e.localizedDescription))
                    default: break
                    }
                }
            }
            DispatchQueue.main.async { self.isStreaming = true; self.bytesSent = 0 }
            setStatus("Connecting", error: nil)
            c.start(queue: queue)
        }
    }

    func stop() { queue.async { [self] in stopLocked() } }

    private func stopLocked() {
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        phase = .idle
        rx = []; reader = RTMPChunk.Reader(); streamID = 0; backlog = 0; sentTotal = 0
        needsKey = true; sentParams = []; sentMeta = false; baseTime = nil
        received = 0; lastAck = 0; windowSize = 2_500_000
        streamKey = ""
        DispatchQueue.main.async { self.isStreaming = false; self.isLive = false; self.status = "Idle" }
    }

    private func fail(_ message: String) {
        let m = redact(message)
        stopLocked()
        DispatchQueue.main.async { self.lastError = m; self.status = "Failed" }
    }

    private func redact(_ s: String) -> String { redactStreamKey(s, key: streamKey) }

    private func setStatus(_ s: String, error: String?) {
        DispatchQueue.main.async { self.status = s; self.lastError = error }
    }

    // MARK: handshake + receive

    private func sendHandshake(_ c: NWConnection) {
        var c1 = [UInt8](repeating: 0, count: 1536)
        for i in 8..<1536 { c1[i] = UInt8.random(in: 0...255) }
        raw([0x03] + c1)
        receiveLoop(c)
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            self.queue.async {
                guard c === self.conn else { return }
                if let data, !data.isEmpty { self.onReceive([UInt8](data)) }
                guard c === self.conn else { return }
                if let err { self.fail(err.localizedDescription) }
                else if isComplete { self.fail("Server closed the connection") }
                else { self.receiveLoop(c) }
            }
        }
    }

    private func onReceive(_ d: [UInt8]) {
        if phase == .handshake {
            rx += d
            guard rx.count >= 1 + 1536 * 2 else { return }
            guard rx[0] == 3 else { fail("Bad RTMP handshake version"); return }
            let s1 = Array(rx[1..<1537])
            let rest = Array(rx[3073...])
            rx = []
            raw(s1) // C2 echoes S1
            phase = .connecting
            sendControl(type: 1, payload: RTMPChunk.be32(UInt32(Self.chunkSize)), chunkSize: 128)
            sendCommand("connect", txn: 1, [.object([AMF0.Pair("app", .string(target!.app)), AMF0.Pair("type", .string("nonprivate")),
                                                      AMF0.Pair("flashVer", .string("FMLE/3.0 (compatible; GogglesView)")),
                                                      AMF0.Pair("tcUrl", .string(target!.tcURL))])])
            if !rest.isEmpty { onReceive(rest) }
            return
        }
        received += d.count
        if received - lastAck >= windowSize {
            lastAck = received
            sendControl(type: 3, payload: RTMPChunk.be32(UInt32(truncatingIfNeeded: received)))
        }
        for m in reader.feed(d) { handle(m) }
    }

    private func handle(_ m: RTMPChunk.Message) {
        switch m.typeID {
        case 5 where m.payload.count >= 4:
            windowSize = max(1, m.payload.prefix(4).reduce(0) { $0 << 8 | Int($1) })
        case 4 where m.payload.count >= 6 && m.payload[1] == 6: // PingRequest -> PingResponse
            sendControl(type: 4, payload: [0, 7] + m.payload[2..<6])
        case 20:
            let v = AMF0.decode(m.payload)
            guard let name = v.first?.string else { return }
            let txn = v.count > 1 ? v[1].number : nil
            switch name {
            case "_result" where phase == .connecting && txn == 1:
                phase = .creating
                sendCommand("releaseStream", txn: 2, [.null, .string(streamKey)])
                sendCommand("FCPublish", txn: 3, [.null, .string(streamKey)])
                sendCommand("createStream", txn: 4, [.null])
            case "_result" where phase == .creating && txn == 4:
                guard v.count > 3, let id = v[3].number else { fail("createStream returned no stream id"); return }
                streamID = UInt32(id)
                sendCommand("publish", txn: 5, [.null, .string(streamKey), .string("live")], stream: streamID)
            case "_error":
                fail("Server rejected command (\(describe(v)))")
            case "onStatus":
                guard let code = v.last?.properties?.first(where: { $0.key == "code" })?.value.string else { return }
                if code == "NetStream.Publish.Start" {
                    phase = .publishing
                    DispatchQueue.main.async { self.isLive = true; self.status = "Live"; self.lastError = nil }
                } else if code.contains("Failed") || code.contains("Rejected") || code.contains("BadName") || code.contains("Unpublish") {
                    fail("Server status: \(code)")
                }
            default: break
            }
        default: break
        }
    }

    private func describe(_ v: [AMF0.Value]) -> String {
        let p = v.last?.properties
        return p?.first(where: { $0.key == "description" })?.value.string
            ?? p?.first(where: { $0.key == "code" })?.value.string ?? "unknown"
    }

    // MARK: sending

    private func raw(_ bytes: [UInt8]) {
        guard let c = conn else { return }
        backlog += bytes.count
        let n = bytes.count
        c.send(content: Data(bytes), completion: .contentProcessed { [weak self, weak c] err in
            guard let self else { return }
            self.queue.async {
                guard c === self.conn else { return }
                self.backlog = max(0, self.backlog - n)
                if let err { self.fail(err.localizedDescription); return }
                self.sentTotal += UInt64(n)
                let t = self.sentTotal
                DispatchQueue.main.async { self.bytesSent = t }
            }
        })
    }

    private func sendControl(type: UInt8, payload: [UInt8], chunkSize: Int = RTMPPublisher.chunkSize) {
        raw(RTMPChunk.encode(csid: 2, typeID: type, streamID: 0, timestamp: 0, payload: payload, chunkSize: chunkSize))
    }

    private func sendCommand(_ name: String, txn: Double, _ args: [AMF0.Value], stream: UInt32 = 0) {
        let payload = AMF0.encode([.string(name), .number(txn)] + args)
        raw(RTMPChunk.encode(csid: 3, typeID: 20, streamID: stream, timestamp: 0, payload: payload, chunkSize: Self.chunkSize))
    }

    /// Thread-safe entry point (also used by the integration test with synthetic frames).
    func submit(avcc: Data, isKeyframe: Bool, parameterSets: [Data], width: Int, height: Int, fps: Double, pts: Double) {
        queue.async { [self] in
            guard phase == .publishing else { return }
            if needsKey && !isKeyframe { return }
            let base = baseTime ?? pts
            baseTime = base
            let ts = UInt32(truncatingIfNeeded: Int(max(0, pts - base) * 1000))

            if isKeyframe, !parameterSets.isEmpty, parameterSets != sentParams {
                let sps = parameterSets.filter { $0.first.map { $0 & 0x1F == 7 } ?? false }
                let pps = parameterSets.filter { $0.first.map { $0 & 0x1F == 8 } ?? false }
                guard let rec = RTMPFLV.avcDecoderConfigurationRecord(sps: sps, pps: pps) else { return }
                if !sentMeta {
                    raw(RTMPChunk.encode(csid: 8, typeID: 18, streamID: streamID, timestamp: 0,
                                         payload: RTMPFLV.onMetaData(width: width, height: height, fps: fps), chunkSize: Self.chunkSize))
                    sentMeta = true
                }
                raw(RTMPChunk.encode(csid: 6, typeID: 9, streamID: streamID, timestamp: ts,
                                     payload: RTMPFLV.videoTag(keyframe: true, sequenceHeader: true, data: rec), chunkSize: Self.chunkSize))
                sentParams = parameterSets
            }
            guard !sentParams.isEmpty else { return }
            if backlog > Self.maxBacklog { needsKey = true; return }
            needsKey = false
            raw(RTMPChunk.encode(csid: 6, typeID: 9, streamID: streamID, timestamp: ts,
                                 payload: RTMPFLV.videoTag(keyframe: isKeyframe, sequenceHeader: false, data: [UInt8](avcc)),
                                 chunkSize: Self.chunkSize))
        }
    }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let avcc = NetworkStreamer.avccData(sampleBuffer) else { return }
        let isKey = NetworkStreamer.isKeyframe(sampleBuffer)
        var w = 0, h = 0, fps = 30.0
        if isKey, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            w = Int(d.width); h = Int(d.height)
            let dur = CMSampleBufferGetDuration(sampleBuffer).seconds
            if dur.isFinite, dur > 0 { fps = (1 / dur).rounded() }
        }
        submit(avcc: avcc, isKeyframe: isKey, parameterSets: isKey ? NetworkStreamer.parameterSets(sampleBuffer) : [],
               width: w, height: h, fps: fps, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    func flush() {}
}

extension NetworkStreamer {
    static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        Recorder.isKeyframe(sb)
    }
}
