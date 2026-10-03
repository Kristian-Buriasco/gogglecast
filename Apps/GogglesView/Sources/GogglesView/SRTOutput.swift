import Foundation
import CoreMedia

enum SRTMode: String, CaseIterable { case caller, listener }

enum SRTPrefs {
    static let libraryPathKey = "srtLibraryPath"
    static let modeKey = "srtMode"
    static let hostKey = "srtHost"
    static let portKey = "srtPort"
    static let latencyKey = "srtLatencyMs"
    static let passphraseKey = "srtPassphrase"
    static let defaultLatency = 120

    static var libraryPath: String? { UserDefaults.standard.string(forKey: libraryPathKey) }
    static var mode: SRTMode { SRTMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .caller }
    static var host: String { clampHost(UserDefaults.standard.string(forKey: hostKey)) }
    static var port: Int { clampPort(UserDefaults.standard.integer(forKey: portKey)) }
    static var latencyMs: Int { clampLatency(UserDefaults.standard.object(forKey: latencyKey) as? Int) }
    static var passphrase: String { UserDefaults.standard.string(forKey: passphraseKey) ?? "" }

    static func clampPort(_ p: Int) -> Int { (1...65535).contains(p) ? p : 9000 }
    static func clampLatency(_ l: Int?) -> Int { min(max(l ?? defaultLatency, 20), 8000) }
    static func clampHost(_ h: String?) -> String {
        let t = h?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? "127.0.0.1" : t
    }
    /// SRT requires 10...79 characters, or empty for no encryption.
    static func passphraseValid(_ p: String) -> Bool { p.isEmpty || (10...79).contains(p.utf8.count) }

    /// What to enter in the receiver. In caller mode we dial out, so the receiver must listen.
    static func receiverHint(mode: SRTMode, port: Int, hasPassphrase: Bool) -> String {
        let pw = hasPassphrase ? "&passphrase=<your passphrase>" : ""
        switch mode {
        case .caller: return "Start the receiver first as listener: srt://:\(port)?mode=listener\(pw)"
        case .listener: return "Receiver connects to this Mac: srt://<this-mac-ip>:\(port)?mode=caller\(pw)"
        }
    }
}

/// Minimal libsrt binding resolved at runtime (never linked). Sends the muxer's
/// MPEG-TS in 1316-byte (7x188) live-mode messages on a private queue; when the
/// non-blocking socket can't accept (EASYNCSND) the rest of the frame is dropped.
final class SRTOutput: ObservableObject, SampleBufferRendering {
    @Published private(set) var isStreaming = false
    @Published private(set) var connected = false
    @Published private(set) var bytesSent: UInt64 = 0
    @Published private(set) var lastError: String?

    private typealias Fn0 = @convention(c) () -> Int32
    private typealias FnSetFlag = @convention(c) (Int32, Int32, UnsafeRawPointer?, Int32) -> Int32
    private typealias FnAddr = @convention(c) (Int32, UnsafePointer<sockaddr>?, Int32) -> Int32
    private typealias FnListen = @convention(c) (Int32, Int32) -> Int32
    private typealias FnAccept = @convention(c) (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias FnSend = @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Int32
    private typealias FnClose = @convention(c) (Int32) -> Int32
    private typealias FnErrStr = @convention(c) () -> UnsafePointer<CChar>?
    private typealias FnErr = @convention(c) (UnsafeMutablePointer<Int32>?) -> Int32

    private struct API {
        let handle: UnsafeMutableRawPointer
        let startup: Fn0, cleanup: Fn0, create: Fn0, setFlag: FnSetFlag
        let connect: FnAddr, bind: FnAddr, listen: FnListen, accept: FnAccept
        let send: FnSend, close: FnClose, lastErrStr: FnErrStr, lastErr: FnErr
    }
    static let symbols = ["srt_startup", "srt_cleanup", "srt_create_socket", "srt_setsockflag", "srt_connect",
                          "srt_bind", "srt_listen", "srt_accept", "srt_send", "srt_close",
                          "srt_getlasterror_str", "srt_getlasterror"]
    // SRT_SOCKOPT / error values from srt.h
    private static let optSndSyn: Int32 = 1, optSender: Int32 = 21, optLatency: Int32 = 23
    private static let optPassphrase: Int32 = 26, optConnTimeo: Int32 = 36, optTranstype: Int32 = 50
    private static let eAsyncSnd: Int32 = 6001 // SRT_EASYNCSND = SRT_EMN(AGAIN, WRAVAIL)

    private let queue = DispatchQueue(label: "SRTOutput.send")
    private let lock = NSLock()   // guards api/listener/client/generation (worker thread + send queue)
    private var api: API?
    private var listener: Int32 = -1 // listening socket, or the caller socket while connecting
    private var client: Int32 = -1
    private var generation = 0
    private var muxer = MPEGTSMuxer()
    private var passphrase = ""
    private var sent: UInt64 = 0

    static func isAvailable() -> Bool { OutputLibrary.resolveSRT() != nil }

    func start(mode: SRTMode, host: String, port: Int, latencyMs: Int, passphrase: String) {
        guard !isStreaming else { return }
        guard SRTPrefs.passphraseValid(passphrase) else { fail("Passphrase must be 10-79 characters"); return }
        guard let path = OutputLibrary.resolveSRT() else { fail("libsrt not found (brew install srt)"); return }
        guard let lib = OutputLibrary.open(path, symbols: Self.symbols) else {
            fail("libsrt at \(path) could not be loaded or lacks required symbols"); return
        }
        func f<T>(_ n: String, _: T.Type) -> T { unsafeBitCast(lib.fns[n]!, to: T.self) }
        let api = API(handle: lib.handle, startup: f("srt_startup", Fn0.self), cleanup: f("srt_cleanup", Fn0.self),
                      create: f("srt_create_socket", Fn0.self), setFlag: f("srt_setsockflag", FnSetFlag.self),
                      connect: f("srt_connect", FnAddr.self), bind: f("srt_bind", FnAddr.self),
                      listen: f("srt_listen", FnListen.self), accept: f("srt_accept", FnAccept.self),
                      send: f("srt_send", FnSend.self), close: f("srt_close", FnClose.self),
                      lastErrStr: f("srt_getlasterror_str", FnErrStr.self), lastErr: f("srt_getlasterror", FnErr.self))
        guard api.startup() >= 0 else { fail("srt_startup failed"); dlclose(lib.handle); return }
        lock.lock(); self.api = api; generation += 1; let gen = generation; self.passphrase = passphrase; lock.unlock()
        queue.async { [self] in muxer = MPEGTSMuxer(); sent = 0 }
        isStreaming = true; connected = false; lastError = nil; bytesSent = 0
        Thread.detachNewThread { [self] in
            switch mode {
            case .caller: callerLoop(api, gen, host, port, latencyMs, passphrase)
            case .listener: listenerLoop(api, gen, port, latencyMs, passphrase)
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        let api = self.api, l = listener, c = client
        listener = -1; client = -1; self.api = nil
        lock.unlock()
        guard let api else { return }
        // Closing the sockets unblocks the worker's accept()/connect().
        if c >= 0 { _ = api.close(c) }
        if l >= 0 { _ = api.close(l) }
        // Leave the worker a moment to exit before unloading the library.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { _ = api.cleanup(); dlclose(api.handle) }
        isStreaming = false; connected = false
    }

    // MARK: worker (own thread: connect/accept block)

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func errText(_ api: API) -> String {
        let s = api.lastErrStr().map { String(cString: $0) } ?? "unknown error"
        return OutputLibrary.redact(s, secret: passphrase)
    }

    private func configure(_ api: API, _ s: Int32, latencyMs: Int, passphrase: String) {
        var live: Int32 = 0 // SRTT_LIVE
        _ = api.setFlag(s, Self.optTranstype, &live, 4)
        var lat = Int32(latencyMs)
        _ = api.setFlag(s, Self.optLatency, &lat, 4)
        var sender = true
        _ = api.setFlag(s, Self.optSender, &sender, 1)
        if !passphrase.isEmpty {
            let b = Array(passphrase.utf8)
            _ = api.setFlag(s, Self.optPassphrase, b, Int32(b.count))
        }
    }

    private func setClient(_ s: Int32, gen: Int, api: API) -> Bool {
        lock.lock()
        guard generation == gen else { lock.unlock(); _ = api.close(s); return false }
        client = s; lock.unlock()
        var blocking = false // SRTO_SNDSYN=false: srt_send fails instead of blocking the send queue
        _ = api.setFlag(s, Self.optSndSyn, &blocking, 1)
        DispatchQueue.main.async { self.connected = true; self.lastError = nil }
        return true
    }

    private func waitWhileConnected(_ gen: Int) {
        while current(gen) {
            lock.lock(); let c = client; lock.unlock()
            if c < 0 { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func callerLoop(_ api: API, _ gen: Int, _ host: String, _ port: Int, _ lat: Int, _ pass: String) {
        while current(gen) {
            var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res, let sa = ai.pointee.ai_addr else {
                report("Cannot resolve \(host)"); Thread.sleep(forTimeInterval: 2); continue
            }
            let s = api.create()
            configure(api, s, latencyMs: lat, passphrase: pass)
            var timeout: Int32 = 3000
            _ = api.setFlag(s, Self.optConnTimeo, &timeout, 4)
            lock.lock(); listener = s; lock.unlock() // lets stop() close it mid-connect
            let rc = api.connect(s, sa, Int32(ai.pointee.ai_addrlen))
            freeaddrinfo(res)
            lock.lock(); let stillMine = listener == s; listener = -1; lock.unlock()
            if rc < 0 || !stillMine {
                if stillMine { report("Connect failed: \(errText(api))"); _ = api.close(s) }
                Thread.sleep(forTimeInterval: 2); continue
            }
            if setClient(s, gen: gen, api: api) { waitWhileConnected(gen) }
        }
    }

    private func listenerLoop(_ api: API, _ gen: Int, _ port: Int, _ lat: Int, _ pass: String) {
        let l = api.create()
        configure(api, l, latencyMs: lat, passphrase: pass)
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = in_port_t(UInt16(port)).bigEndian; sin.sin_addr.s_addr = INADDR_ANY
        var blocking = false // inherited by accepted sockets
        _ = api.setFlag(l, Self.optSndSyn, &blocking, 1)
        let bound = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { api.bind(l, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound >= 0, api.listen(l, 1) >= 0 else {
            report("Listen on port \(port) failed: \(errText(api))"); _ = api.close(l)
            DispatchQueue.main.async { self.isStreaming = false }
            return
        }
        lock.lock()
        guard generation == gen else { lock.unlock(); _ = api.close(l); return }
        listener = l; lock.unlock()
        while current(gen) {
            let s = api.accept(l, nil, nil)
            if s < 0 {
                if current(gen) { report("Accept failed: \(errText(api))"); Thread.sleep(forTimeInterval: 1) }
                continue
            }
            if setClient(s, gen: gen, api: api) { waitWhileConnected(gen) }
        }
    }

    private func report(_ msg: String) { DispatchQueue.main.async { self.lastError = msg } }
    private func fail(_ msg: String) { lastError = msg; isStreaming = false }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            lock.lock(); let api = self.api; let c = client; lock.unlock()
            guard let api, c >= 0, let avcc = NetworkStreamer.avccData(sampleBuffer) else { return }
            let att = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]])?.first
            let isKey = !((att?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            let ts = muxer.mux(avcc: avcc, isKeyframe: isKey,
                               parameterSets: isKey ? NetworkStreamer.parameterSets(sampleBuffer) : [],
                               presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
            var off = 0
            ts.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                while off < ts.count {
                    let n = min(Self.messageSize, ts.count - off)
                    if api.send(c, base + off, Int32(n)) < 0 {
                        var code: Int32 = 0
                        _ = api.lastErr(&code)
                        // Send buffer full: drop the rest of this frame, keep the connection.
                        if code != Self.eAsyncSnd { dropClient(c, api) }
                        return
                    }
                    off += n
                    sent += UInt64(n)
                }
            }
            let total = sent
            DispatchQueue.main.async { self.bytesSent = total }
        }
    }

    /// 7 TS packets = 1316 bytes, the SRT live-mode default payload.
    static let messageSize = 7 * MPEGTSMuxer.packetSize

    private func dropClient(_ c: Int32, _ api: API) {
        lock.lock(); if client == c { client = -1 }; lock.unlock()
        _ = api.close(c)
        DispatchQueue.main.async { self.connected = false }
    }

    func flush() {}
}
