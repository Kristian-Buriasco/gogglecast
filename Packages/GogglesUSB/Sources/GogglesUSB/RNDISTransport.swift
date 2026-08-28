import Foundation
import CLibusb
import GogglesProtocol

// ─────────────────────────────────────────────────────────────────────────
// Task 1.5: RNDIS/USB transport (design §3.1, §5.2). Reference: the Python
// prototype's `rndis.py` (`find_device`, `send_encapsulated_command`,
// `get_encapsulated_response`, `wait_notification`, `rndis_initialize`,
// `rndis_set`) and `stream.py`'s `main()` device-setup sequence -- see the
// task-1.5 report for exact provenance notes.
//
// Task 1.6: closes the abstraction-level gap task 1.5 deliberately left
// open. `RNDISTransport` now conforms to `GogglesTransport`'s documented
// contract exactly like `MockTransport` does: `inbound` yields UDP:9003
// *payload* bytes (not raw Ethernet frames), and `send(_:)` takes a
// UDP-payload `Data` and does its own Ethernet/IPv4/UDP framing
// internally. This required two additions layered on top of task 1.5's
// USB/RNDIS bring-up, both ported from the Python prototype:
//
//   1. ARP resolution of the goggles' current RNDIS MAC at connect time
//      (`ARPResolver`, design §3.2) -- the goggles rotate this MAC every
//      reboot, so it is resolved fresh every connect and never persisted
//      or hardcoded anywhere in this codebase.
//   2. Inbound Ethernet-frame filtering (design §5.2): ARP requests for
//      the host IP get an ARP reply; everything else is parsed as UDP via
//      `RawNet.parseUDP` and filtered to source port 9003, with only the
//      payload forwarded to `inbound`. ARP traffic from the goggles' IP
//      also continuously re-learns/refreshes the goggles MAC during the
//      normal receive loop, matching `stream.py`'s main loop.
// ─────────────────────────────────────────────────────────────────────────

/// USB-descriptor-level identity of the connected goggles, extracted once
/// at `RNDISTransport` connect time.
///
/// Lives in `GogglesUSB`, not `GogglesProtocol`: every field here (bus/
/// address, `bcdDevice`, USB string descriptors) is a USB-specific concept
/// with no meaning for a future non-USB transport (e.g. a real Wi-Fi UDP
/// transport talking straight to the goggles' AP once liveview-over-WiFi
/// is used directly) -- so it does not belong in the transport-agnostic
/// protocol core `GogglesProtocol` is built to be. Mirrors the banner
/// `stream.py`'s `main()` prints at startup (`usb.util.get_string` for
/// `iProduct`/`iSerialNumber`, `dev.idVendor`/`idProduct`/`bcdDevice`,
/// `dev.bus`/`dev.address`).
public struct DeviceInfo: Sendable, Equatable {
    public let product: String?
    public let serial: String?
    public let idVendor: UInt16
    public let idProduct: UInt16
    public let bcdDevice: UInt16
    public let bus: UInt8
    public let address: UInt8
}

/// Errors thrown by `RNDISTransport` at connect time or during a send.
public enum RNDISTransportError: Error, CustomStringConvertible {
    /// No USB device matching `RNDISTransport.vendorID`/`productID` was found.
    case deviceNotFound
    /// A libusb call returned a negative (`libusb_error`) result code.
    case libusbCall(String, Int32)

    public var description: String {
        switch self {
        case .deviceNotFound:
            let vid = String(format: "%04x", RNDISTransport.vendorID)
            let pid = String(format: "%04x", RNDISTransport.productID)
            return "Goggles not found over USB (VID:PID \(vid):\(pid))"
        case .libusbCall(let call, let code):
            let name = libusb_error_name(code).map { String(cString: $0) } ?? "?"
            return "\(call) failed: \(name) (\(code))"
        }
    }
}

/// `GogglesTransport` conformer speaking RNDIS over real USB hardware via
/// libusb (design §3.1, §5.2). macOS has no kernel RNDIS driver for this
/// composite device, so this type detaches whatever the OS attached and
/// claims both interfaces itself, then hand-rolls the CDC
/// SEND/GET_ENCAPSULATED_COMMAND control sequence to bring the RNDIS link
/// up, exactly as the Python prototype's `rndis.py`/`stream.py` do.
///
/// Claiming IF0/IF1 requires root on macOS (raw USB interface claim on a
/// composite device needs an entitlement `sudo` provides) -- see the
/// task-1.5 report for exactly what was/wasn't verified against real
/// hardware in this session.
public final class RNDISTransport: GogglesTransport {

    // MARK: - Constants (design §3.1 / rndis.py)

    public static let vendorID: UInt16 = 0x2CA3
    public static let productID: UInt16 = 0x0020

    private static let ctrlInterface: Int32 = 0
    private static let dataInterface: Int32 = 1

    private static let epInterruptIn: UInt8 = 0x82
    private static let epBulkIn: UInt8 = 0x81
    private static let epBulkOut: UInt8 = 0x01

    /// UDP source port `send`'s built frames use, and the destination port
    /// on the goggles side. Matches `stream.py`'s `SRC_PORT`/`DST_PORT`.
    private static let udpSrcPort: UInt16 = 54321
    private static let udpDstPort: UInt16 = 9003
    /// Inbound frames are only forwarded to `inbound` if their UDP source
    /// port is this (the goggles' outbound port) -- matches `stream.py`'s
    /// `sport != DST_PORT` filter and `MockTransport`'s identical filter.
    private static let expectedInboundSrcPort: UInt16 = 9003

    /// §5.2: "a pool of 16 in-flight 64 KB transfers submitted round-robin."
    private static let transferPoolSize = 16
    private static let transferBufferSize = 64 * 1024

    /// Raw value of `LIBUSB_TRANSFER_TYPE_BULK` (libusb.h) -- used as a
    /// plain integer instead of the enum-typed constant since the
    /// `libusb_transfer.type` struct field is declared `unsigned char`
    /// (i.e. a raw byte), not the enum type itself.
    private static let transferTypeBulk: UInt8 = 2

    // MARK: - GogglesTransport

    /// Inbound UDP:9003 payload bytes -- matches `GogglesTransport`'s doc
    /// comment and `MockTransport`'s contract exactly (task 1.6). ARP
    /// requests for the host IP and any other non-matching traffic are
    /// filtered out internally, never surfaced here.
    public let inbound: AsyncStream<Data>

    /// Builds a full Ethernet/IPv4/UDP frame addressed to the ARP-resolved
    /// goggles MAC/IP (`RawNet.buildUDP`) and writes it synchronously to
    /// IF1's bulk-OUT endpoint. `frame` is a UDP-payload `Data` (an 8-byte
    /// outer header + body, as built by `WireProtocol`) -- matching
    /// `GogglesTransport`'s documented contract, not a raw Ethernet frame.
    /// Synchronous per the task brief: §5.2's async-pool requirement is
    /// specifically about removing the inbound read gap, not about
    /// outbound sends.
    public func send(_ frame: Data) throws {
        let mac = currentGogglesMac()
        let ethernetFrame = RawNet.buildUDP(
            srcMac: ARPResolver.hostMac, dstMac: mac,
            srcIp: ARPResolver.hostIp, dstIp: ARPResolver.gogglesIp,
            srcPort: Self.udpSrcPort, dstPort: Self.udpDstPort,
            payload: frame
        )
        try writeEthernetFrame(ethernetFrame)
    }

    /// Raw bulk-OUT write shared by `send(_:)`, the connect-time ARP
    /// resolution, and the inbound-ARP-request auto-responder.
    ///
    /// Task 3.7, design §9.3 scenario 1: on this hardware/macOS combo, a
    /// real physical unplug was observed to NOT reliably deliver
    /// `LIBUSB_TRANSFER_NO_DEVICE` to the pending pooled bulk-IN reads
    /// (`handleBulkInCompletion`'s own such handling, added earlier in this
    /// task, never fired against real hardware) -- the outstanding reads
    /// just went silent with no completion callback at all, while
    /// `Pipeline.swift`'s periodic ~2s handshake-resend timer kept calling
    /// this method and swallowing whatever it threw (`send()`'s `catch`
    /// there only logs to stderr), so the helper was observed wedged
    /// oscillating `.handshaking`/`.stalled` forever with the interfaces
    /// still claimed against a now-dead handle, never reaching `.noDevice`,
    /// even after the goggles were physically replugged and re-enumerated
    /// as a new USB device the old handle has no relationship to.
    ///
    /// This OUT path, by contrast, DOES reliably surface the failure
    /// synchronously via `libusb_bulk_transfer`'s return code -- so this is
    /// the actual disconnect-detection path for this hardware. Any error
    /// here is treated as fatal: `close()` (idempotent, safe to call from
    /// any thread/re-entrantly) tears the transport down the same way an
    /// explicit `reconnect()`/unplug-via-bulk-IN would, finishing `inbound`
    /// so `runPipeline` ends and the existing pipelineTask-completion path
    /// in `HelperService` drives `.noDevice`.
    private func writeEthernetFrame(_ frame: Data) throws {
        guard let handle else {
            throw RNDISTransportError.libusbCall("send (no device handle)", 0)
        }
        var wrapped = RNDIS.wrapPacketMsg(frame)
        let wrappedCount = wrapped.count
        var transferred: Int32 = 0
        let rc: Int32 = wrapped.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return libusb_bulk_transfer(handle, Self.epBulkOut, base, Int32(wrappedCount), &transferred, 500)
        }
        guard rc == 0 else {
            let name = libusb_error_name(rc).map { String(cString: $0) } ?? "?"
            FileHandle.standardError.write(Data(("[RNDISTransport] bulk-OUT write failed (\(name)/\(rc)) -- treating as device gone, closing transport\n").utf8))
            close()
            throw RNDISTransportError.libusbCall("libusb_bulk_transfer(OUT)", rc)
        }
    }

    /// Thread-safe read of the (connect-time-resolved, continuously
    /// re-learned per design §5.2) goggles MAC.
    private func currentGogglesMac() -> Data {
        poolLock.lock()
        defer { poolLock.unlock() }
        return _gogglesMac
    }

    /// Thread-safe update of the goggles MAC (initial resolution in
    /// `init`, or a later learn/refresh from inbound ARP traffic).
    private func updateGogglesMac(_ mac: Data) {
        poolLock.lock()
        _gogglesMac = mac
        poolLock.unlock()
    }

    // MARK: - Public state

    /// USB-descriptor identity captured once at connect time.
    public let deviceInfo: DeviceInfo

    /// The ARP-resolved goggles RNDIS MAC (design §3.2). Never hardcoded,
    /// never persisted across launches -- resolved fresh at connect time
    /// in `init`, and continuously re-learned/refreshed thereafter from
    /// any ARP traffic seen from `ARPResolver.gogglesIp` (design §5.2).
    /// Guarded by `poolLock` (read via `currentGogglesMac()`) since it's
    /// touched from both the event thread (learning) and `send(_:)`'s
    /// caller thread (reading).
    public var gogglesMac: Data {
        currentGogglesMac()
    }

    /// Diagnostic-only: non-nil if connect-time resolution had to fall
    /// back to the multi-subnet sweep (design §3.2 step 4) instead of
    /// resolving `ARPResolver.gogglesIp` directly. Logged at connect time
    /// regardless; also exposed here for a caller/test to inspect.
    public let arpSweepDiagnostic: ARPResolver.SweepDiagnostic?

    private var _gogglesMac: Data = Data()

    // MARK: - Private state

    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    private var claimedInterfaces: [Int32] = []

    private let continuation: AsyncStream<Data>.Continuation
    private var eventThread: Thread?

    /// Guards `isRunning`/`outstandingTransfers` -- touched from both the
    /// libusb event thread (inside transfer-completion callbacks) and
    /// whichever thread calls `deinit`/shutdown.
    private let poolLock = NSLock()
    private var isRunning = true
    private var outstandingTransfers = 0
    private let allTransfersDone = DispatchSemaphore(value: 0)

    private var pooledTransfers: [UnsafeMutablePointer<libusb_transfer>] = []
    private var transferBuffers: [UnsafeMutablePointer<UInt8>] = []

    // MARK: - Init / connect

    /// Finds the goggles over USB, detaches/claims IF0+IF1, performs the
    /// RNDIS INITIALIZE + packet-filter SET control sequence (design
    /// §3.1), extracts `deviceInfo`, and starts the async bulk-IN transfer
    /// pool + its dedicated high-QoS libusb event-pumping thread (§5.2).
    ///
    /// Throws `RNDISTransportError` on any failure; on throw, any USB
    /// resources already acquired (device handle, claimed interfaces,
    /// libusb context) are released before the error propagates -- no
    /// partial state is left open.
    public init() throws {
        var contextPtr: OpaquePointer?
        let initRC = libusb_init(&contextPtr)
        guard initRC == 0, let context = contextPtr else {
            throw RNDISTransportError.libusbCall("libusb_init", initRC)
        }

        guard let deviceHandle = libusb_open_device_with_vid_pid(context, Self.vendorID, Self.productID) else {
            libusb_exit(context)
            throw RNDISTransportError.deviceNotFound
        }

        var claimed: [Int32] = []
        var resolvedMac = Data()
        var resolvedSweepDiagnostic: ARPResolver.SweepDiagnostic?
        do {
            for iface in [Self.ctrlInterface, Self.dataInterface] {
                let active = libusb_kernel_driver_active(deviceHandle, iface)
                if active == 1 {
                    // Best-effort: a failed detach isn't necessarily fatal
                    // (matches stream.py's try/except around detach) --
                    // the subsequent claim call is the real gate.
                    _ = libusb_detach_kernel_driver(deviceHandle, iface)
                }
                let claimRC = libusb_claim_interface(deviceHandle, iface)
                guard claimRC == 0 else {
                    throw RNDISTransportError.libusbCall("libusb_claim_interface(IF\(iface))", claimRC)
                }
                claimed.append(iface)
            }

            // §3.1 sequence step 1: REMOTE_NDIS_INITIALIZE_MSG, then read
            // the response (best-effort interrupt notification in between).
            try Self.sendEncapsulatedCommand(deviceHandle, data: RNDIS.initializeMsg())
            _ = Self.waitNotification(deviceHandle)
            _ = try Self.getEncapsulatedResponse(deviceHandle)

            // §3.1 sequence step 2: REMOTE_NDIS_SET_MSG on
            // OID_GEN_CURRENT_PACKET_FILTER with 0x0035
            // (DIRECTED|BROADCAST|ALL_MULTICAST|PROMISCUOUS).
            let filterBits: UInt32 =
                RNDIS.NDIS_PACKET_TYPE_DIRECTED | RNDIS.NDIS_PACKET_TYPE_BROADCAST
                | RNDIS.NDIS_PACKET_TYPE_ALL_MULTICAST | RNDIS.NDIS_PACKET_TYPE_PROMISCUOUS
            var filterValue = Data()
            filterValue.append(UInt8(filterBits & 0xFF))
            filterValue.append(UInt8((filterBits >> 8) & 0xFF))
            filterValue.append(UInt8((filterBits >> 16) & 0xFF))
            filterValue.append(UInt8((filterBits >> 24) & 0xFF))
            try Self.sendEncapsulatedCommand(
                deviceHandle,
                data: RNDIS.setMsg(oid: RNDIS.OID_GEN_CURRENT_PACKET_FILTER, value: filterValue)
            )
            _ = Self.waitNotification(deviceHandle)
            _ = try Self.getEncapsulatedResponse(deviceHandle)

            // Task 1.6 / design §3.2: with the RNDIS link up, resolve the
            // goggles' current MAC before any data is yielded on
            // `inbound`. Runs synchronously on this (init) thread using
            // blocking bulk transfers, since the async transfer pool and
            // event thread haven't started yet -- no other consumer of
            // IF1's bulk endpoints exists at this point.
            var pendingResolutionFrames: [Data] = []
            let resolved = try ARPResolver.resolve(
                sendFrame: { frame in try Self.writeEthernetFrameBlocking(deviceHandle, frame) },
                receiveFrame: { timeout in
                    Self.readEthernetFrameBlocking(deviceHandle, timeout: timeout, pending: &pendingResolutionFrames)
                },
                log: { message in
                    FileHandle.standardError.write(Data(("[RNDISTransport] " + message + "\n").utf8))
                }
            )
            resolvedMac = resolved.mac
            resolvedSweepDiagnostic = resolved.sweepDiagnostic
        } catch {
            for iface in claimed {
                libusb_release_interface(deviceHandle, iface)
            }
            libusb_close(deviceHandle)
            libusb_exit(context)
            throw error
        }

        self.ctx = context
        self.handle = deviceHandle
        self.claimedInterfaces = claimed
        self.deviceInfo = Self.extractDeviceInfo(handle: deviceHandle)
        self._gogglesMac = resolvedMac
        self.arpSweepDiagnostic = resolvedSweepDiagnostic

        var continuation: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream<Data> { continuation = $0 }
        self.continuation = continuation

        startBulkInPool()
        startEventThread()
    }

    deinit {
        shutdown()
    }

    // MARK: - Shutdown

    /// Task 2.2: releases IF0/IF1 and finishes `inbound` *without* waiting
    /// for every strong reference to this instance to drop first.
    ///
    /// Phase 1's assumption ("drop the last strong ref, `deinit` runs, the
    /// interfaces get released") holds for `gvcli` because its
    /// SIGINT/process-exit path nils `currentTransport` and calls `exit(0)`
    /// in the same breath -- whether `deinit` actually finishes before the
    /// OS reclaims the device doesn't matter. It does *not* hold for a
    /// long-lived daemon: `GogglesHelper --xpc`'s running pipeline `Task`
    /// (`GogglesPipeline.runPipeline`) holds its own strong reference to
    /// this transport for the entire span of that `async` call (as a
    /// function parameter), so nil-ing the *global* `currentTransport`
    /// elsewhere never drops the reference that's actually keeping this
    /// instance alive -- the pipeline `Task` would otherwise spin forever
    /// on a hardware connection nothing is reading from anymore (found via
    /// this task's own `--xpc` hardware verification: fan-out's 5s-linger
    /// teardown left the previous pipeline `Task` running indefinitely).
    ///
    /// Calling `close()` explicitly breaks that deadlock: it runs
    /// `shutdown()` (idempotent, same as `deinit`'s own call) immediately,
    /// which finishes `inbound`'s `AsyncStream` -- ending
    /// `runPipeline`'s inbound-consumer loop and letting that `Task`
    /// actually complete on its own, at which point its held reference
    /// drops and `deinit` (now a no-op `shutdown()` re-entry) runs too.
    public func close() {
        shutdown()
    }

    /// Cancels every pooled transfer, waits (bounded) for the event thread
    /// to drain them, then releases the claimed interfaces and tears down
    /// the libusb device handle/context. Idempotent-safe to call multiple
    /// times (from both `close()` and `deinit`) -- `isRunning`/`poolLock`
    /// guard the transfer-cancellation body, and `continuation.finish()` is
    /// itself documented safe to call more than once.
    private func shutdown() {
        poolLock.lock()
        let wasRunning = isRunning
        isRunning = false
        let outstanding = outstandingTransfers
        poolLock.unlock()

        continuation.finish()

        if wasRunning, let ctx {
            for transfer in pooledTransfers {
                libusb_cancel_transfer(transfer)
            }
            if outstanding > 0 {
                // Pump events on THIS thread so cancellation completions
                // fire even if the dedicated event thread has already
                // exited its loop check -- bounded so a stuck device can't
                // hang deinit forever.
                let deadline = Date().addingTimeInterval(2.0)
                while Date() < deadline {
                    poolLock.lock()
                    let remaining = outstandingTransfers
                    poolLock.unlock()
                    if remaining <= 0 { break }
                    var tv = timeval(tv_sec: 0, tv_usec: 50_000)
                    libusb_handle_events_timeout(ctx, &tv)
                }
            }
        }

        // Give the dedicated event-pumping thread a moment to notice
        // isRunning == false and exit its loop before we free the
        // transfers/buffers it might still be touching.
        _ = allTransfersDone.wait(timeout: .now() + 2.0)

        for transfer in pooledTransfers {
            libusb_free_transfer(transfer)
        }
        for buffer in transferBuffers {
            buffer.deallocate()
        }
        pooledTransfers.removeAll()
        transferBuffers.removeAll()

        if let handle {
            for iface in claimedInterfaces {
                libusb_release_interface(handle, iface)
            }
            libusb_close(handle)
        }
        if let ctx {
            libusb_exit(ctx)
        }
        handle = nil
        ctx = nil
    }

    // MARK: - Bulk-IN transfer pool (§5.2)

    private func startBulkInPool() {
        guard let handle else { return }
        poolLock.lock()
        outstandingTransfers = Self.transferPoolSize
        poolLock.unlock()

        for _ in 0..<Self.transferPoolSize {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.transferBufferSize)
            guard let transfer = libusb_alloc_transfer(0) else {
                buffer.deallocate()
                poolLock.lock()
                outstandingTransfers -= 1
                poolLock.unlock()
                continue
            }
            transfer.pointee.dev_handle = handle
            transfer.pointee.endpoint = Self.epBulkIn
            transfer.pointee.type = Self.transferTypeBulk
            transfer.pointee.timeout = 0
            transfer.pointee.buffer = buffer
            transfer.pointee.length = Int32(Self.transferBufferSize)
            transfer.pointee.callback = rndisTransportBulkInCallback
            transfer.pointee.user_data = Unmanaged.passUnretained(self).toOpaque()

            transferBuffers.append(buffer)
            pooledTransfers.append(transfer)
            libusb_submit_transfer(transfer)
        }
    }

    /// Invoked by `rndisTransportBulkInCallback` (the C-callable
    /// trampoline below) whenever one pooled bulk-IN transfer completes.
    /// Unwraps any RNDIS_PACKET_MSG structures in the completed buffer
    /// into raw Ethernet frames and filters each one (design §5.2, matching
    /// `stream.py`'s main receive loop) before immediately resubmitting
    /// the same transfer (round-robin reuse, per §5.2) unless shutdown is
    /// in progress:
    ///
    ///   - An ARP request targeting the host IP gets an ARP reply sent
    ///     back (dispatched off this thread -- see `respondToARPRequest`).
    ///   - Any ARP traffic (reply or request, gratuitous or not) whose
    ///     sender is the goggles' IP re-learns/refreshes `gogglesMac`, in
    ///     case it changes mid-session (goggles reboot without a full app
    ///     reconnect).
    ///   - Everything else is parsed as UDP (`RawNet.parseUDP`) and, if
    ///     its source port is 9003, its payload is yielded to `inbound`
    ///     -- exactly `MockTransport`'s filter, so the two are
    ///     interchangeable at this boundary. Non-UDP, wrong-port, and
    ///     malformed frames are silently skipped, matching what a real
    ///     consumer would see (this mirrors `MockTransport`'s documented
    ///     behavior, not a gap -- unknown/malformed traffic at the
    ///     Ethernet/ARP/UDP layer isn't a "state" design §8.6 asks us to
    ///     log, unlike unrecognized higher-level packet types, which
    ///     `WireProtocol` already logs).
    fileprivate func handleBulkInCompletion(_ transfer: UnsafeMutablePointer<libusb_transfer>) {
        if transfer.pointee.status == LIBUSB_TRANSFER_COMPLETED {
            let length = Int(transfer.pointee.actual_length)
            if length > 0, let buffer = transfer.pointee.buffer {
                let data = Data(bytes: buffer, count: length)
                for frame in RNDIS.unwrapPacketMsg(data) {
                    handleInboundEthernetFrame(frame)
                }
            }
        } else if transfer.pointee.status == LIBUSB_TRANSFER_NO_DEVICE {
            // Task 3.7, design §9.3 scenario 1: physical USB unplug. libusb
            // reports every in-flight bulk-IN transfer as
            // LIBUSB_TRANSFER_NO_DEVICE once it notices the device is gone.
            // The old code fell straight through to the unconditional
            // resubmit below regardless of status -- `libusb_submit_transfer`
            // on a vanished device fails immediately with no further
            // callback, so every one of the 16 pooled transfers silently
            // went dead without ever finishing `inbound`. That left
            // `runPipeline`'s inbound-consumer loop parked forever awaiting
            // a `Data` that would never come, so the pipeline `Task` never
            // completed, `currentTransport` never went nil, and
            // `HelperService` never saw its pipelineTask-completion path
            // fire -- the helper stayed wedged in `.live`/`.stalled`
            // indefinitely, with no reconnect on replug (verified against
            // real hardware while implementing this task).
            //
            // Fix: flip `isRunning` false and finish `inbound` right here,
            // the same two things `shutdown()` does, so this transfer (and
            // the ~15 siblings independently hitting this same branch within
            // the same unplug event) fall into the "not stillRunning" path
            // below instead of resubmitting -- ending `runPipeline` on its
            // own and letting the existing pipelineTask-completion/
            // `.noDevice` logic in `HelperService` run exactly as it does
            // for any other transport-driven end of the pipeline. A later
            // `shutdown()` call (from `close()`/`deinit`) sees
            // `isRunning` already false and skips its cancel-and-wait loop
            // entirely, since there is nothing left in flight to cancel.
            poolLock.lock()
            isRunning = false
            poolLock.unlock()
            continuation.finish()
        }

        poolLock.lock()
        let stillRunning = isRunning
        poolLock.unlock()

        if stillRunning {
            _ = libusb_submit_transfer(transfer)
        } else {
            poolLock.lock()
            outstandingTransfers -= 1
            let done = outstandingTransfers <= 0
            poolLock.unlock()
            if done {
                allTransfersDone.signal()
            }
        }
    }

    /// One inbound Ethernet frame's worth of filtering (design §5.2). See
    /// `handleBulkInCompletion`'s doc comment for the full rationale.
    private func handleInboundEthernetFrame(_ frame: Data) {
        if let arp = RawNet.parseARP(frame) {
            if arp.senderIp == ARPResolver.gogglesIp {
                updateGogglesMac(arp.senderMac)
            }
            if arp.op == 1, arp.targetIp == ARPResolver.hostIp {
                respondToARPRequest(from: arp.senderMac, senderIp: arp.senderIp)
            }
            return
        }

        guard let udp = RawNet.parseUDP(frame), udp.srcPort == Self.expectedInboundSrcPort else {
            return
        }
        continuation.yield(udp.payload)
    }

    /// Sends an ARP reply for the host IP back to `senderMac`/`senderIp`,
    /// per design §5.2 ("ARP request for 192.168.60.1 -> emit an ARP
    /// reply"). Dispatched onto a background queue rather than written
    /// synchronously here: this runs on the dedicated libusb event thread
    /// (inside a transfer-completion callback fired from
    /// `libusb_handle_events_timeout`), and issuing a synchronous
    /// `libusb_bulk_transfer` re-enters libusb's event handling from
    /// within its own callback, which is not safe to do on this thread.
    private func respondToARPRequest(from senderMac: Data, senderIp: String) {
        let reply = RawNet.buildARPReply(
            srcMac: ARPResolver.hostMac, srcIp: ARPResolver.hostIp,
            dstMac: senderMac, dstIp: senderIp
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.writeEthernetFrame(reply)
        }
    }

    // MARK: - Event-pumping thread (§5.2)

    /// Runs `libusb_handle_events_timeout` in a tight loop on a dedicated
    /// high-QoS thread, per §5.2 ("pumped on a dedicated high-QoS
    /// thread... removes the read gap between iterations entirely" --
    /// unlike the Python prototype's single synchronous 200ms-timeout read
    /// per loop iteration).
    private func startEventThread() {
        let thread = Thread { [weak self] in
            self?.eventLoop()
        }
        thread.name = "RNDISTransport.libusbEvents"
        thread.qualityOfService = .userInteractive
        thread.start()
        eventThread = thread
    }

    private func eventLoop() {
        guard let ctx else { return }
        while true {
            poolLock.lock()
            let running = isRunning
            poolLock.unlock()
            if !running { break }
            var tv = timeval(tv_sec: 0, tv_usec: 50_000)
            libusb_handle_events_timeout(ctx, &tv)
        }
    }

    // MARK: - Blocking bulk I/O for connect-time ARP resolution

    /// RNDIS-wraps `frame` and writes it via a synchronous, 500ms-timeout
    /// bulk-OUT transfer. Used only during `init`'s ARP-resolution phase
    /// (before `handle`/the event thread exist), via a raw `deviceHandle`
    /// rather than an instance method -- Swift's two-phase init forbids
    /// calling instance methods on `self` before every stored property has
    /// a value, which `_gogglesMac` (set from this call's result) does
    /// not yet at this point in `init`.
    private static func writeEthernetFrameBlocking(_ handle: OpaquePointer, _ frame: Data) throws {
        var wrapped = RNDIS.wrapPacketMsg(frame)
        let count = wrapped.count
        var transferred: Int32 = 0
        let rc: Int32 = wrapped.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return libusb_bulk_transfer(handle, epBulkOut, base, Int32(count), &transferred, 500)
        }
        guard rc == 0 else {
            throw RNDISTransportError.libusbCall("libusb_bulk_transfer(OUT, ARP resolution)", rc)
        }
    }

    /// Blocks for up to `timeout` for one inbound Ethernet frame,
    /// RNDIS-unwrapped. A single bulk-IN read can yield multiple
    /// RNDIS_PACKET_MSGs; any beyond the first are queued in `pending` and
    /// drained before issuing another hardware read. Returns `nil` if
    /// nothing arrived within `timeout` (a genuine libusb timeout) or if
    /// `timeout` is already non-positive.
    private static func readEthernetFrameBlocking(
        _ handle: OpaquePointer, timeout: TimeInterval, pending: inout [Data]
    ) -> Data? {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        guard timeout > 0 else { return nil }
        let timeoutMs = UInt32(min(timeout, 30) * 1000)
        var buffer = [UInt8](repeating: 0, count: 16384)
        var transferred: Int32 = 0
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
            libusb_bulk_transfer(handle, epBulkIn, buf.baseAddress, Int32(buf.count), &transferred, timeoutMs)
        }
        guard rc == 0, transferred > 0 else { return nil }
        let data = Data(buffer.prefix(Int(transferred)))
        let frames = RNDIS.unwrapPacketMsg(data)
        guard !frames.isEmpty else { return nil }
        pending = Array(frames.dropFirst())
        return frames.first
    }

    // MARK: - Control-transfer helpers (§3.1)

    private static func sendEncapsulatedCommand(_ handle: OpaquePointer, data: Data) throws {
        var mutableData = data
        let count = data.count
        let rc: Int32 = mutableData.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return libusb_control_transfer(
                handle, 0x21, 0x00, 0, UInt16(ctrlInterface), base, UInt16(count), 1000
            )
        }
        guard rc >= 0 else {
            throw RNDISTransportError.libusbCall("SEND_ENCAPSULATED_COMMAND", rc)
        }
    }

    private static func getEncapsulatedResponse(_ handle: OpaquePointer, maxLength: Int = 4096) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
            libusb_control_transfer(handle, 0xA1, 0x01, 0, UInt16(ctrlInterface), buf.baseAddress, UInt16(maxLength), 1000)
        }
        guard rc >= 0 else {
            throw RNDISTransportError.libusbCall("GET_ENCAPSULATED_RESPONSE", rc)
        }
        return Data(buffer.prefix(Int(rc)))
    }

    /// Best-effort 8-byte interrupt-endpoint read ("response available"
    /// notification). Failure is non-fatal per §3.1 -- always returns
    /// `nil` on error rather than throwing.
    private static func waitNotification(_ handle: OpaquePointer, timeoutMs: UInt32 = 1500) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 8)
        var transferred: Int32 = 0
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
            libusb_interrupt_transfer(handle, epInterruptIn, buf.baseAddress, 8, &transferred, timeoutMs)
        }
        guard rc == 0 else { return nil }
        return Data(buffer.prefix(Int(transferred)))
    }

    // MARK: - DeviceInfo extraction

    private static func extractDeviceInfo(handle: OpaquePointer) -> DeviceInfo {
        guard let device = libusb_get_device(handle) else {
            return DeviceInfo(product: nil, serial: nil, idVendor: vendorID, idProduct: productID, bcdDevice: 0, bus: 0, address: 0)
        }
        var descriptor = libusb_device_descriptor()
        let rc = libusb_get_device_descriptor(device, &descriptor)
        guard rc == 0 else {
            return DeviceInfo(product: nil, serial: nil, idVendor: vendorID, idProduct: productID, bcdDevice: 0, bus: 0, address: 0)
        }
        let product = stringDescriptor(handle: handle, index: descriptor.iProduct)
        let serial = stringDescriptor(handle: handle, index: descriptor.iSerialNumber)
        let bus = libusb_get_bus_number(device)
        let address = libusb_get_device_address(device)
        return DeviceInfo(
            product: product, serial: serial,
            idVendor: descriptor.idVendor, idProduct: descriptor.idProduct, bcdDevice: descriptor.bcdDevice,
            bus: bus, address: address
        )
    }

    private static func stringDescriptor(handle: OpaquePointer, index: UInt8) -> String? {
        guard index != 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
            libusb_get_string_descriptor_ascii(handle, index, buf.baseAddress, Int32(buf.count))
        }
        guard rc > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(rc)), as: UTF8.self)
    }
}

// MARK: - C callback trampoline

/// A plain top-level (non-capturing) function so it can be passed directly
/// as a `libusb_transfer_cb_fn` (`@convention(c)`) function pointer --
/// Swift closures that capture context cannot be used as C function
/// pointers, so the actual `RNDISTransport` instance is recovered from
/// `transfer.pointee.user_data` (set to an unretained `Unmanaged` pointer
/// to `self` when the transfer was submitted) instead of being captured.
private func rndisTransportBulkInCallback(_ transferPtr: UnsafeMutablePointer<libusb_transfer>?) {
    guard let transferPtr, let userData = transferPtr.pointee.user_data else { return }
    let transport = Unmanaged<RNDISTransport>.fromOpaque(userData).takeUnretainedValue()
    transport.handleBulkInCompletion(transferPtr)
}
