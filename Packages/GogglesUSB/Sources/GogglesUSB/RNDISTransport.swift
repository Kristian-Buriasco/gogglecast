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
// Scoping decision (documented per the task brief's step 5/6 wording,
// which this type follows literally): `inbound` yields raw *Ethernet*
// frames unwrapped from RNDIS_PACKET_MSG (`RNDIS.unwrapPacketMsg`'s
// output, unfiltered), and `send(_:)` wraps its argument directly via
// `RNDIS.wrapPacketMsg` with no Ethernet/IPv4/UDP framing added. This is a
// narrower abstraction level than `GogglesTransport`'s own doc comment
// describes (`Transport.swift`: "UDP:9003 payload bytes", matching what
// `MockTransport` produces after its own Ethernet/UDP parsing). The
// mismatch is deliberate for this task, not an oversight: task 1.5 is
// scoped to "the USB transport" (device discovery, control transfers, the
// bulk pool, RNDIS wrap/unwrap) per its brief, explicitly leaving the
// Ethernet+IPv4+UDP framing and ARP MAC-resolution dance (Python's
// `rawnet.build_udp`/`parse_udp` + `resolve_goggles_mac`) for a later task
// to layer on top -- either inside this type or as a small adapter
// wrapping it. `RawNet` (already built in task 1.1) is exactly the tool
// that later task will reach for. Until that lands, a caller driving
// `RNDISTransport` directly gets raw Ethernet frames on `inbound` and must
// itself supply already-Ethernet-framed bytes to `send`, NOT bare
// WireProtocol outer-header frames -- this is flagged clearly here and in
// the task-1.5 report so the next task doesn't miss it.
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

    /// §5.2: "a pool of 16 in-flight 64 KB transfers submitted round-robin."
    private static let transferPoolSize = 16
    private static let transferBufferSize = 64 * 1024

    /// Raw value of `LIBUSB_TRANSFER_TYPE_BULK` (libusb.h) -- used as a
    /// plain integer instead of the enum-typed constant since the
    /// `libusb_transfer.type` struct field is declared `unsigned char`
    /// (i.e. a raw byte), not the enum type itself.
    private static let transferTypeBulk: UInt8 = 2

    // MARK: - GogglesTransport

    public let inbound: AsyncStream<Data>

    /// Wraps `frame` via `RNDIS.wrapPacketMsg` and writes it synchronously
    /// to IF1's bulk-OUT endpoint. Synchronous per the task brief: §5.2's
    /// async-pool requirement is specifically about removing the inbound
    /// read gap, not about outbound sends.
    public func send(_ frame: Data) throws {
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
            throw RNDISTransportError.libusbCall("libusb_bulk_transfer(OUT)", rc)
        }
    }

    // MARK: - Public state

    /// USB-descriptor identity captured once at connect time.
    public let deviceInfo: DeviceInfo

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

    /// Cancels every pooled transfer, waits (bounded) for the event thread
    /// to drain them, then releases the claimed interfaces and tears down
    /// the libusb device handle/context. Idempotent-safe to call from
    /// `deinit`; a live `RNDISTransport` has no other call site for it in
    /// this task (no explicit `close()` in the `GogglesTransport`
    /// protocol), so `deinit` is the only trigger.
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
    /// into raw Ethernet frames, yields each to `inbound`, then
    /// immediately resubmits the same transfer (round-robin reuse, per
    /// §5.2) unless shutdown is in progress.
    fileprivate func handleBulkInCompletion(_ transfer: UnsafeMutablePointer<libusb_transfer>) {
        if transfer.pointee.status == LIBUSB_TRANSFER_COMPLETED {
            let length = Int(transfer.pointee.actual_length)
            if length > 0, let buffer = transfer.pointee.buffer {
                let data = Data(bytes: buffer, count: length)
                for frame in RNDIS.unwrapPacketMsg(data) {
                    continuation.yield(frame)
                }
            }
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
