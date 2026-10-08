import Foundation
import GVNetCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

let usage = """
gvnet: DJI Goggles 3 liveview over the network (UDP 9003). No USB access needed.

usage: gvnet [--host IP] [--bind IP] [--port N] [--local-port N] [--out FILE|-|udp://HOST:PORT] [--seconds N] [--stats]

  --host        goggles address (default 192.168.60.2, the USB/RNDIS link; use the goggles' Wi-Fi address otherwise)
  --bind        local address to bind (default 0.0.0.0; the USB link uses 192.168.60.1)
  --port        goggles port (default 9003)
  --local-port  local port (default 54321)
  --out         raw H.264 (Annex B) destination: a file, '-' for stdout (default), or udp://HOST:PORT
  --seconds     stop after N seconds
  --stats       print packet/frame counters to stderr once a second

Turn on Share Liveview on the goggles first. View the stream with, for example:
  gvnet | ffplay -f h264 -fflags nobuffer -
"""

struct Options {
    var host = "192.168.60.2", bind: String? = nil
    var port: UInt16 = 9003, localPort: UInt16 = 54321
    var out = "-", seconds: Double? = nil, stats = false
}

func parse(_ args: [String]) -> Options? {
    var o = Options(), i = 0
    func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
        switch args[i] {
        case "--host": guard let v = value() else { return nil }; o.host = v
        case "--bind": guard let v = value() else { return nil }; o.bind = v
        case "--port": guard let v = value().flatMap(UInt16.init) else { return nil }; o.port = v
        case "--local-port": guard let v = value().flatMap(UInt16.init) else { return nil }; o.localPort = v
        case "--out": guard let v = value() else { return nil }; o.out = v
        case "--seconds": guard let v = value().flatMap(Double.init) else { return nil }; o.seconds = v
        case "--stats": o.stats = true
        default: return nil
        }
        i += 1
    }
    return o
}

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else { err(usage); exit(2) }

// Output sink.
var fileHandle: FileHandle?
var udpOut: UDPSocket?
if options.out == "-" {
    fileHandle = FileHandle.standardOutput
} else if options.out.hasPrefix("udp://") {
    let hostPort = options.out.dropFirst(6).split(separator: ":")
    guard hostPort.count == 2, let p = UInt16(hostPort[1]) else { err("bad --out \(options.out)"); exit(2) }
    do { udpOut = try UDPSocket(bind: nil, localPort: 0, peer: String(hostPort[0]), peerPort: p) } catch { err("\(error)"); exit(1) }
} else {
    FileManager.default.createFile(atPath: options.out, contents: nil)
    guard let h = FileHandle(forWritingAtPath: options.out) else { err("cannot write \(options.out)"); exit(1) }
    fileHandle = h
}

signal(SIGPIPE, SIG_IGN)
let socket: UDPSocket
do {
    socket = try UDPSocket(bind: options.bind, localPort: options.localPort, peer: options.host, peerPort: options.port)
} catch { err("gvnet: \(error)"); exit(1) }

var session = StreamSession()
for p in session.start() { socket.send(p) }
err("gvnet: handshake sent to \(options.host):\(options.port); waiting for video (Share Liveview must be on)")

let begin = Date()
var lastStats = begin
var wasStarted = false
while true {
    let now = Date()
    if let s = options.seconds, now.timeIntervalSince(begin) >= s { break }
    if let packet = socket.receive(timeoutMs: 50) {
        let actions = session.receive(packet, now: Date())
        for r in actions.replies { socket.send(r) }
        for nal in actions.nals {
            if let h = fileHandle {
                do { try h.write(contentsOf: nal) } catch { exit(0) } // reader went away
            }
            udpOut?.send(nal)
        }
    }
    for p in session.tick(now: Date()) { socket.send(p) }
    if session.started != wasStarted {
        wasStarted = session.started
        err(wasStarted ? "gvnet: picture started" : "gvnet: signal lost, waiting for the next keyframe")
    }
    if options.stats, now.timeIntervalSince(lastStats) >= 1 {
        lastStats = now
        err("gvnet: video packets \(session.videoPackets), frames \(session.framesOut), dropped \(session.droppedFrames)\(session.started ? "" : ", waiting for keyframe")")
    }
}
