import Foundation
import CoreMedia
import Network

enum NetStreamPrefs {
    static let hostKey = "netStreamHost"
    static let portKey = "netStreamPort"
    static let autoStartKey = "netStreamAutoStart"
    static var host: String {
        let h = UserDefaults.standard.string(forKey: hostKey) ?? ""
        return h.isEmpty ? "127.0.0.1" : h
    }
    static var port: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(p) ? p : 5000
    }
}

/// Muxes slice samples to MPEG-TS and sends them over UDP. `enqueue` only
/// hops to a private queue; sends are fire-and-forget and dropped when too
/// many are in flight so a stalled socket never blocks decoding.
final class NetworkStreamer: ObservableObject, SampleBufferRendering {
    @Published private(set) var isStreaming = false
    @Published private(set) var bytesSent: UInt64 = 0
    @Published private(set) var lastError: String?

    static let packetsPerDatagram = 7
    private static let maxInFlight = 64

    private let queue = DispatchQueue(label: "NetworkStreamer")
    private var connection: NWConnection?
    private var muxer = MPEGTSMuxer()
    private var inFlight = 0
    private var pendingBytes: UInt64 = 0
    private var active = false
    private var userEnabled = false
    private var wantHost = ""
    private var wantPort: NWEndpoint.Port?
    private var attempt = 0
    private var reconnectItem: DispatchWorkItem?

    func start(host: String, port: Int) {
        queue.async { [self] in
            stopLocked()
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
                publish(error: "Invalid port"); return
            }
            wantHost = host; wantPort = nwPort; attempt = 0
            userEnabled = true
            connect()
            DispatchQueue.main.async { self.isStreaming = true; self.bytesSent = 0; self.lastError = nil }
        }
    }

    private func connect() {
        guard userEnabled, let nwPort = wantPort else { return }
        muxer = MPEGTSMuxer()
        let conn = NWConnection(host: NWEndpoint.Host(wantHost), port: nwPort, using: .udp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            self.queue.async {
                guard conn === self.connection else { return }
                switch state {
                case .failed(let e):
                    self.publish(error: e.localizedDescription)
                    self.dropConnection()
                    self.scheduleRestart()
                case .waiting(let e): self.publish(error: e.localizedDescription)
                case .ready: self.attempt = 0; self.publish(error: nil)
                default: break
                }
            }
        }
        connection = conn
        active = true
        conn.start(queue: queue)
    }

    /// Backoff restart (1, 2, 4 ... capped at 15 s) while the user still has the stream enabled.
    private func scheduleRestart() {
        guard userEnabled else { return }
        let delay = ReconnectBackoff.delay(attempt: attempt)
        attempt += 1
        reconnectItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.userEnabled, self.connection == nil else { return }
            self.connect()
        }
        reconnectItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stop() { queue.async { [self] in stopLocked() } }

    private func dropConnection() {
        active = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        inFlight = 0
        pendingBytes = 0
    }

    private func stopLocked() {
        userEnabled = false
        reconnectItem?.cancel()
        reconnectItem = nil
        dropConnection()
        DispatchQueue.main.async { self.isStreaming = false }
    }

    private func publish(error: String?) {
        DispatchQueue.main.async { self.lastError = error }
    }

    // MARK: SampleBufferRendering

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard active, let conn = connection else { return }
            guard let avcc = Self.avccData(sampleBuffer) else { return }
            let isKey = Recorder.isKeyframe(sampleBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let ts = muxer.mux(avcc: avcc, isKeyframe: isKey,
                               parameterSets: isKey ? Self.parameterSets(sampleBuffer) : [],
                               presentationTime: pts)
            send(ts, on: conn)
        }
    }

    func flush() {}

    private func send(_ ts: Data, on conn: NWConnection) {
        let chunk = Self.packetsPerDatagram * MPEGTSMuxer.packetSize
        var off = 0
        while off < ts.count {
            let end = min(off + chunk, ts.count)
            let datagram = ts.subdata(in: off..<end)
            off = end
            if inFlight >= Self.maxInFlight { continue } // drop, never stall decode
            inFlight += 1
            conn.send(content: datagram, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.queue.async {
                    guard conn === self.connection else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    if let err { self.publish(error: err.localizedDescription); return }
                    self.pendingBytes += UInt64(datagram.count)
                    let total = self.pendingBytes
                    DispatchQueue.main.async { self.bytesSent = total }
                }
            })
        }
    }

    // MARK: CoreMedia helpers

    static func avccData(_ sb: CMSampleBuffer) -> Data? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let n = CMBlockBufferGetDataLength(bb)
        guard n > 0 else { return nil }
        var data = Data(count: n)
        let st = data.withUnsafeMutableBytes {
            $0.baseAddress.map { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0) } ?? kCMBlockBufferStructureAllocationFailedErr
        }
        return st == kCMBlockBufferNoErr ? data : nil
    }

    static func parameterSets(_ sb: CMSampleBuffer) -> [Data] {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return [] }
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                          parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                          nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { i in
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil) == noErr,
                  let ptr else { return nil }
            return Data(bytes: ptr, count: size)
        }
    }
}
