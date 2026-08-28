import Foundation
import GogglesProtocol
#if canImport(Darwin)
import Darwin
#endif

// ─────────────────────────────────────────────────────────────────────────
// Task 1.7: the shared driving loop behind `gvcli stream` and `gvcli
// replay`. Ports `stream.py`'s `main()` receive loop (handshake, I-frame
// request/retry, ack-per-frame-boundary (complete or not), SPS/IDR
// started-gate, fps reporting) on top of the transport-agnostic pieces tasks 1.1-1.6 already
// built (`GogglesTransport`, `WireProtocol`, `FrameReassembler`) -- no
// protocol logic is re-derived here, this file only wires those pieces
// together and adds the ack-tracking / started-gate / stats bookkeeping
// that lives directly in `stream.py`'s `main()` rather than in any of the
// ported modules.
//
// Task 2.2: extracted out of the `gvcli` executable into the
// `GogglesPipeline` library (see Package.swift) so `Helper/GogglesHelper`
// can drive the exact same loop for both its `--stdout` mode (a straight
// `OutputSink.standardOutput()` sink, no delegate) and its `--xpc` mode (no
// sink, a `PipelineDelegate` that fans NAL/state/stats events out to every
// connected subscriber) -- see `PipelineDelegate.swift`. `gvcli` itself is
// unaffected: `runPipeline(transport:outPath:stats:)`'s signature/behavior
// is unchanged, `delegate` simply defaults to `nil`.
// ─────────────────────────────────────────────────────────────────────────

/// Global handle to the live transport/sink, so `SIGINT`/`SIGTERM` (see
/// `installSigintHandler` and `GogglesHelper`'s own `SIGTERM` handler) can
/// release them from outside the running async task. Deliberately the
/// *only* long-lived strong reference `runPipeline` keeps to either:
/// dropping it (`= nil`) is what triggers `RNDISTransport`/`MockTransport`'s
/// `deinit` (closing libusb/interfaces or finishing the replay stream)
/// synchronously and deterministically, which is exactly the "clean
/// release of IF0/IF1" behavior the task-1.7 brief requires `gvcli stream`
/// (and, as of task 2.2, `GogglesHelper`) to exhibit on exit. `public` so
/// `GogglesHelper` can install its own `SIGTERM` handler mirroring
/// `installSigintHandler`'s pattern without a second copy of this state.
public var currentTransport: GogglesTransport?
public var currentSink: OutputSink?
private var sigintSource: DispatchSourceSignal?

/// Installs a `SIGINT` handler for `gvcli stream`: on Ctrl-C, closes the
/// output sink and releases `currentTransport` (synchronously running
/// `RNDISTransport.deinit`'s interface-release/libusb-teardown) before
/// exiting, rather than leaving the interfaces claimed for the process to
/// be killed uncleanly. This is what lets a subsequent `stream.py` run
/// claim IF0/IF1 again (task-1.7 brief's exit criterion).
public func installSigintHandler() {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        FileHandle.standardError.write(Data("\n[gvcli] Interrupted -- releasing USB interfaces and exiting...\n".utf8))
        currentSink?.close()
        currentSink = nil
        currentTransport = nil
        exit(0)
    }
    source.resume()
    sigintSource = source
}

/// Per-frame started-gate state, matching `stream.py`'s `state["sps"]` /
/// `state["started"]`: output doesn't begin until a parameter-set NAL
/// (type 7 SPS or 8 PPS) has been seen, followed by an IDR (type 5) --
/// every NAL before that point is silently dropped, same as Python's
/// `flush_frame`.
private struct FrameGateState {
    var sps: Data?
    var started = false
}

/// Runs the full receive/decode/emit pipeline against `transport` --
/// handshake, I-frame request + 1.5s retry until started, 2s data-silence
/// handshake resend, per-frame-boundary ack (complete or not), `FrameReassembler`-driven
/// reassembly, SPS/IDR started-gate, and Annex-B emission to `outPath` (if
/// given) -- optionally reporting per-second fps/bitrate/drop stats to
/// stderr.
///
/// Returns when `transport.inbound` finishes (a `MockTransport` replay
/// reaching EOF) or the process is interrupted (`installSigintHandler`,
/// for a live `RNDISTransport`).
///
/// This overload keeps `gvcli`'s exact original behavior (path-based sink,
/// `[gvcli]`-prefixed stderr banners around opening it). `delegate`
/// defaults to `nil` and is unused by `gvcli` itself; see the
/// `sink:`-based overload below for `GogglesHelper`'s entry point.
public func runPipeline(
    transport: GogglesTransport,
    outPath: String?,
    stats: Bool,
    delegate: PipelineDelegate? = nil
) async throws {
    let sink: OutputSink?
    if let outPath {
        FileHandle.standardError.write(Data(
            "[gvcli] Opening \(outPath) for writing (if it's a FIFO, this blocks until a reader attaches -- start ffplay on it now)...\n".utf8
        ))
        sink = try OutputSink(path: outPath)
        FileHandle.standardError.write(Data("[gvcli] Output sink ready.\n".utf8))
    } else {
        sink = nil
    }
    try await runPipeline(transport: transport, sink: sink, stats: stats, delegate: delegate)
}

/// Task 2.2: `GogglesHelper`'s entry point -- takes an already-constructed
/// `OutputSink?` (or none at all, for pure `--xpc` fan-out with no file
/// output) instead of a path, and drives `delegate`'s hooks alongside
/// whatever the sink does. Everything below this point is the actual
/// pipeline logic, shared verbatim by both overloads and both
/// `gvcli`/`GogglesHelper`.
public func runPipeline(
    transport: GogglesTransport,
    sink: OutputSink?,
    stats: Bool,
    delegate: PipelineDelegate? = nil
) async throws {
    currentTransport = transport
    defer { currentTransport = nil }
    currentSink = sink
    defer {
        sink?.close()
        currentSink = nil
    }

    let sessionId = WireProtocol.randomSessionId()
    FileHandle.standardError.write(Data(String(format: "[gvcli] Session ID: 0x%04X\n", sessionId).utf8))

    let state = PipelineState()
    let reassembler = FrameReassembler()

    func send(_ frame: Data) {
        do {
            try currentTransport?.send(frame)
        } catch {
            FileHandle.standardError.write(Data("[gvcli] send failed: \(error)\n".utf8))
        }
    }

    // Initial handshake, then (matching stream.py's main(): a 0.5s pause)
    // the first I-frame request.
    let handshakeSeq = await state.nextSeq()
    send(WireProtocol.buildHandshake(seq: handshakeSeq, sessionId: sessionId))
    FileHandle.standardError.write(Data("[gvcli] Sent handshake.\n".utf8))
    await state.markRx()
    try? await Task.sleep(nanoseconds: 500_000_000)
    let iframeSeq = await state.nextSeq()
    send(WireProtocol.requestIFrameTelemetry(seq: iframeSeq, sessionId: sessionId))
    await state.markIframeRequested()
    FileHandle.standardError.write(Data("[gvcli] Requested fresh I-frame (DUML 02:B3).\n".utf8))

    var gate = FrameGateState()
    var sawFirstVideoPacket = false

    // Reproduces stream.py's ack-on-every-frame-boundary behavior
    // (`FrameBoundaryAckTracker.swift`), independent of whatever
    // `FrameReassembler`'s own age/distance eviction does -- see that
    // file for the stream.py correspondence.
    var ackTracker = FrameBoundaryAckTracker()

    try await withThrowingTaskGroup(of: Void.self) { group in
        // MARK: inbound-packet consumer
        group.addTask {
            for await payload in transport.inbound {
                await state.markRx()
                guard let outer = WireProtocol.parseOuter(payload) else { continue }
                WireProtocol.logUnknownPacketType(outer.pktType, context: "gvcli inbound")

                guard outer.pktType == WireProtocol.packetTypeVideo else {
                    continue
                }
                guard outer.body.count >= 12 else { continue }

                if !sawFirstVideoPacket {
                    sawFirstVideoPacket = true
                    delegate?.pipelineDidBeginReceivingVideo()
                }

                let base = outer.body.startIndex
                let frameNum = outer.body[base + 8]

                // Frame-boundary ack: fires whenever this packet's
                // frame_num differs from the previous packet's, covering
                // the *previous* frame's accumulated seq range regardless
                // of whether FrameReassembler ever completed it. Matches
                // stream.py's boundary-transition ack -- see
                // `FrameBoundaryAckTracker.swift`.
                if let range = ackTracker.recordPacket(frameNum: frameNum, seq: outer.seq) {
                    let ackSeq = await state.nextSeq()
                    send(WireProtocol.buildAck(startSeq: range.first, endSeq: range.last, seq: ackSeq, sessionId: sessionId))
                }

                guard let nal = reassembler.process(videoPayload: outer.body, receivedAt: Date()) else {
                    await state.updateDroppedTotal(reassembler.droppedFrameCount)
                    continue
                }
                await state.updateDroppedTotal(reassembler.droppedFrameCount)

                // Completion ack: fires immediately when a frame
                // completes, in addition to (never instead of) the
                // boundary ack above -- matches stream.py's
                // frag-count-reached branch.
                if let range = ackTracker.recordCompletion(frameNum: frameNum) {
                    let ackSeq = await state.nextSeq()
                    send(WireProtocol.buildAck(startSeq: range.first, endSeq: range.last, seq: ackSeq, sessionId: sessionId))
                }

                // Started-gate: matches stream.py's flush_frame. NAL type
                // is the low 5 bits of the first byte after the 4-byte
                // 00 00 00 01 start code FrameReassembler always prepends.
                let headerOffset = 4
                let nalType: UInt8 = nal.count > headerOffset ? (nal[nal.startIndex + headerOffset] & 0x1F) : 0xFF

                if !gate.started {
                    if nalType == 7 || nalType == 8 {
                        gate.sps = nal
                    } else if nalType == 5, let sps = gate.sps {
                        gate.started = true
                        await state.markStarted()
                        FileHandle.standardError.write(Data("[gvcli] Got param-set + IDR, starting output.\n".utf8))
                        sink?.write(sps)
                        sink?.write(nal)
                        await state.recordEmittedFrame(bytes: sps.count + nal.count)
                        let spsType: UInt8 = sps.count > headerOffset ? (sps[sps.startIndex + headerOffset] & 0x1F) : 0xFF
                        let hostTime = DispatchTime.now().uptimeNanoseconds
                        delegate?.pipeline(didEmitNAL: sps, nalType: spsType, isParameterSet: true, hostTime: hostTime)
                        delegate?.pipeline(didEmitNAL: nal, nalType: nalType, isParameterSet: false, hostTime: hostTime)
                        delegate?.pipelineDidStart()
                    }
                    // else: still waiting for a parameter set or an IDR;
                    // this NAL is dropped, matching Python's flush_frame.
                } else {
                    sink?.write(nal)
                    await state.recordEmittedFrame(bytes: nal.count)
                    let isParamSet = (nalType == 7 || nalType == 8)
                    delegate?.pipeline(didEmitNAL: nal, nalType: nalType, isParameterSet: isParamSet, hostTime: DispatchTime.now().uptimeNanoseconds)
                }
            }
        }

        // MARK: periodic handshake-resend / I-frame-retry timer
        group.addTask {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }
                let timers = await state.snapshotTimers()
                let now = Date()
                if now.timeIntervalSince(timers.lastRx) > 2.0 {
                    let seq = await state.nextSeq()
                    send(WireProtocol.buildHandshake(seq: seq, sessionId: sessionId))
                    FileHandle.standardError.write(Data("[gvcli] No data for 2s, resending handshake.\n".utf8))
                    await state.markRx()
                    delegate?.pipelineWentSilent()
                }
                if !timers.started, now.timeIntervalSince(timers.lastIframe) > 1.5 {
                    let seq = await state.nextSeq()
                    send(WireProtocol.requestIFrameTelemetry(seq: seq, sessionId: sessionId))
                    await state.markIframeRequested()
                }
            }
        }

        // MARK: per-second stats reporting (`--stats`'s stderr line, and/or
        // `delegate.pipelineDidUpdateStats` -- the latter fires whenever a
        // delegate is present, independent of `stats`, since GogglesHelper's
        // `--xpc` mode wants per-second `StreamStats` fan-out regardless of
        // whether gvcli's own `--stats` text flag was ever a factor here)
        if stats || delegate != nil {
            group.addTask {
                var second = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    second += 1
                    let (fps, bytes, drops) = await state.snapshotAndResetPerSecond()
                    let (cumFrames, cumBytes, cumDrops) = await state.cumulativeSnapshot()
                    let kbps = Double(bytes) * 8.0 / 1000.0
                    if stats {
                        FileHandle.standardError.write(Data(
                            String(
                                format: "[stats] t=%4ds fps=%3d bitrate=%9.1fkbps drops=%d cum_frames=%d cum_bytes=%d cum_drops=%d\n",
                                second, fps, kbps, drops, cumFrames, cumBytes, cumDrops
                            ).utf8
                        ))
                    }
                    delegate?.pipelineDidUpdateStats(PipelineStats(
                        fps: fps,
                        bitrateKbps: kbps,
                        drops: drops,
                        cumulativeFrames: cumFrames,
                        cumulativeBytes: cumBytes,
                        cumulativeDrops: cumDrops
                    ))
                }
            }
        }

        // The inbound consumer is the only task that ever returns on its
        // own (transport.inbound finishing, either at a replay's EOF or
        // because `installSigintHandler` dropped `currentTransport` and
        // triggered `deinit`'s `continuation.finish()`); the timer/stats
        // tasks loop until cancelled. Waiting for the first completion and
        // then cancelling the rest drains the group cleanly either way.
        try await group.next()
        group.cancelAll()
    }

    let final = await state.cumulativeSnapshot()
    FileHandle.standardError.write(Data(
        "[gvcli] Done. Emitted \(final.frames) NALs, \(final.bytes) bytes, \(final.drops) dropped frame(s).\n".utf8
    ))
}
