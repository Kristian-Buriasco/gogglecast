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

/// Task multidevice-picker item 3: per-pipeline handle to the live
/// transport/sink, replacing the old process-wide `currentTransport`/
/// `currentSink` globals. `HelperService` used to read those globals for
/// real control flow (deciding whether to declare `.noDevice`, where to
/// send `requestIFrame`) -- harmless with exactly one device claimable at a
/// time, but a real correctness bug the moment multi-claim exists (device
/// A unplugging could read/act on device B's transport, since both would
/// share the same pair of globals). Each `runPipeline` call now owns its
/// own `PipelineHandle` instance (one per device, for `HelperService`'s
/// per-device pipelines; one for the process, for `gvcli`), and a caller
/// that needs to read/release "the transport for pipeline X" holds onto
/// that specific handle instead of a shared global.
///
/// `transport`/`sink` are `fileprivate(set)`: only `runPipeline` itself
/// (in this file) ever assigns them; every other reader (a caller wanting
/// to inspect whether the transport is still alive, or to force a release)
/// only ever reads.
///
/// LOW fix (multi-device picker review round 2): `transport`/`sink` are
/// genuinely written from more than one thread in `HelperService`'s
/// multi-device usage -- `runPipeline`'s own body (whatever thread its
/// `Task` runs on) assigns/clears them at the pipeline's start/end, while
/// `HelperService.teardownHardware`/`releaseAllActivePipelines` can call
/// `releaseSynchronously()` concurrently (from `stateQueue` or a signal
/// handler's queue), and `requestIFrame` reads `.transport` from
/// `stateQueue` while any of that could be happening. This is a
/// pre-existing shape from before the multi-device change (the single
/// process-wide globals had the same kind of unsynchronized access), but
/// it's now exercised far more often -- every linger expiry and every
/// `reconnect()`, not just the old SIGINT-then-`exit(0)` path, where the
/// process was about to die anyway. A plain `NSLock` around every read/
/// write closes this cheaply without changing any call site's code (the
/// public surface -- `transport`/`sink` as stored properties,
/// `releaseSynchronously()` -- is unchanged).
public final class PipelineHandle {
    private let lock = NSLock()
    private var _transport: GogglesTransport?
    private var _sink: OutputSink?

    public fileprivate(set) var transport: GogglesTransport? {
        get { lock.lock(); defer { lock.unlock() }; return _transport }
        set { lock.lock(); _transport = newValue; lock.unlock() }
    }
    public fileprivate(set) var sink: OutputSink? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    public init() {}

    /// Synchronously releases this handle's transport/sink (closes the
    /// sink, drops the transport -- triggering `RNDISTransport`/
    /// `MockTransport`'s `deinit` teardown deterministically, same as the
    /// old global-nilling did). Safe to call multiple times, and from any
    /// thread.
    public func releaseSynchronously() {
        // `sink?.close()` deliberately happens outside the lock -- it's
        // `OutputSink`'s own I/O call, not this handle's state, and
        // holding `lock` across it would serialize unrelated callers
        // (another thread's `.transport` read, say) behind however long
        // that close takes for no benefit. `sink` is read (and cleared)
        // under the lock immediately before/after, so the property itself
        // stays consistent.
        let sinkToClose = sink
        sink = nil
        transport = nil
        sinkToClose?.close()
    }
}

/// Process-wide registry of currently-running pipelines' handles, used
/// ONLY for process-exit cleanup (`installSigintHandler`/`GogglesHelper`'s
/// `SIGTERM` handler both need to release *whatever* is currently claimed
/// before the process dies, regardless of which device it belongs to --
/// that is a legitimately process-wide concern, unlike the per-device
/// control-flow reads `HelperService` used to do against the old globals).
/// Never read for control-flow decisions -- only ever iterated wholesale on
/// the way out.
private let handleRegistryLock = NSLock()
private var handleRegistry: [ObjectIdentifier: PipelineHandle] = [:]

private func registerHandle(_ handle: PipelineHandle) {
    handleRegistryLock.lock()
    handleRegistry[ObjectIdentifier(handle)] = handle
    handleRegistryLock.unlock()
}

private func unregisterHandle(_ handle: PipelineHandle) {
    handleRegistryLock.lock()
    handleRegistry.removeValue(forKey: ObjectIdentifier(handle))
    handleRegistryLock.unlock()
}

/// Releases every currently-registered pipeline's transport/sink
/// synchronously. Called by `installSigintHandler` (`gvcli`) and
/// `GogglesHelper`'s own `SIGTERM` handler on the way to `exit(0)`, so
/// every claimed device (there is normally exactly one for `gvcli`, and
/// potentially several for the `--xpc` helper under multi-claim) gets its
/// USB interfaces released cleanly before the process dies, rather than
/// left claimed for the OS to reclaim uncleanly.
public func releaseAllActivePipelines() {
    handleRegistryLock.lock()
    let handles = Array(handleRegistry.values)
    handleRegistryLock.unlock()
    for handle in handles {
        handle.releaseSynchronously()
    }
}

private var sigintSource: DispatchSourceSignal?

/// Installs a `SIGINT` handler for `gvcli stream`: on Ctrl-C, releases
/// every currently-active pipeline (synchronously running
/// `RNDISTransport.deinit`'s interface-release/libusb-teardown) before
/// exiting, rather than leaving the interfaces claimed for the process to
/// be killed uncleanly. This is what lets a subsequent `stream.py` run
/// claim IF0/IF1 again (task-1.7 brief's exit criterion).
public func installSigintHandler() {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        FileHandle.standardError.write(Data("\n[gvcli] Interrupted -- releasing USB interfaces and exiting...\n".utf8))
        releaseAllActivePipelines()
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
    delegate: PipelineDelegate? = nil,
    handle: PipelineHandle = PipelineHandle(),
    ackMode: AckMode = .fromEnvironment()
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
    try await runPipeline(transport: transport, sink: sink, stats: stats, delegate: delegate, handle: handle, ackMode: ackMode)
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
    delegate: PipelineDelegate? = nil,
    handle: PipelineHandle = PipelineHandle(),
    ackMode: AckMode = .fromEnvironment()
) async throws {
    handle.transport = transport
    handle.sink = sink
    registerHandle(handle)
    defer {
        unregisterHandle(handle)
        handle.sink?.close()
        handle.sink = nil
        handle.transport = nil
    }

    let sessionId = WireProtocol.randomSessionId()
    FileHandle.standardError.write(Data(String(format: "[gvcli] Session ID: 0x%04X\n", sessionId).utf8))
    FileHandle.standardError.write(Data("[gvcli] Ack mode: \(ackMode.rawValue)\(ackMode == .cumulativeWindow ? " (EXPERIMENTAL cumulative receive-window acks)" : "")\n".utf8))

    let state = PipelineState()
    let reassembler = FrameReassembler()

    func send(_ frame: Data) {
        do {
            try handle.transport?.send(frame)
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
    // Experimental alternative (`AckMode.cumulativeWindow`) -- see
    // `WindowAckTracker.swift` for the protocol rationale.
    var windowAckTracker = WindowAckTracker()

    func sendWindowAck(_ ackSeq: UInt16) async {
        let seq = await state.nextSeq()
        send(WireProtocol.buildAck(startSeq: ackSeq, endSeq: ackSeq, seq: seq, sessionId: sessionId))
        await state.recordWindowAck(ackSeq)
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        // MARK: inbound-packet consumer
        group.addTask {
            for await payload in transport.inbound {
                await state.markRx()
                guard let outer = WireProtocol.parseOuter(payload) else { continue }
                WireProtocol.logUnknownPacketType(outer.pktType, context: "gvcli inbound")
                await state.noteInbound(pktType: outer.pktType, seq: outer.seq, body: outer.body)

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
                await state.markVideoRx()

                if ackMode == .cumulativeWindow {
                    if let ackSeq = windowAckTracker.recordPacket(seq: outer.seq) {
                        await sendWindowAck(ackSeq)
                    }
                }

                // Frame-boundary ack: fires whenever this packet's
                // frame_num differs from the previous packet's, covering
                // the *previous* frame's accumulated seq range regardless
                // of whether FrameReassembler ever completed it. Matches
                // stream.py's boundary-transition ack -- see
                // `FrameBoundaryAckTracker.swift`.
                if ackMode == .frameRange, let range = ackTracker.recordPacket(frameNum: frameNum, seq: outer.seq) {
                    let ackSeq = await state.nextSeq()
                    send(WireProtocol.buildAck(startSeq: range.first, endSeq: range.last, seq: ackSeq, sessionId: sessionId))
                    await state.recordWindowAck(range.first)
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
                if ackMode == .frameRange {
                    if let range = ackTracker.recordCompletion(frameNum: frameNum) {
                        let ackSeq = await state.nextSeq()
                        send(WireProtocol.buildAck(startSeq: range.first, endSeq: range.last, seq: ackSeq, sessionId: sessionId))
                        await state.recordWindowAck(range.first)
                    }
                } else if let ackSeq = windowAckTracker.flush() {
                    await sendWindowAck(ackSeq)
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
                // Cumulative-window mode only: if video has paused for
                // >200ms, re-send the last cumulative ack (at most every
                // 200ms tick) so a lost/ignored ack can never leave the
                // goggles' send window blocked waiting on us.
                if ackMode == .cumulativeWindow {
                    let w = await state.windowAckSnapshot()
                    if let last = w.lastAck,
                       now.timeIntervalSince(w.lastVideoRx) > 0.2,
                       now.timeIntervalSince(w.lastAckSent) > 0.2 {
                        await sendWindowAck(last)
                    }
                }
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
                    let lastAck = await state.windowAckSnapshot().lastAck
                    let proto = await state.snapshotAndResetProto(lastAck: lastAck)
                    if stats {
                        FileHandle.standardError.write(Data(
                            String(
                                format: "[stats] t=%4ds fps=%3d bitrate=%9.1fkbps drops=%d cum_frames=%d cum_bytes=%d cum_drops=%d\n",
                                second, fps, kbps, drops, cumFrames, cumBytes, cumDrops
                            ).utf8
                        ))
                        FileHandle.standardError.write(Data("[proto] t=\(String(format: "%4d", second))s \(proto)\n".utf8))
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
