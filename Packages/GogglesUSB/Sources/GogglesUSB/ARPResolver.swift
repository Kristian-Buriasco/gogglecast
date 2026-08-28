import Foundation
import GogglesProtocol

// ─────────────────────────────────────────────────────────────────────────
// Task 1.6: ARP resolution of the goggles' current RNDIS MAC (design §3.2).
//
// The goggles rotate their RNDIS MAC on every reboot (confirmed against
// real hardware -- see the Python prototype's `stream.py` commit that
// replaced its hardcoded `GOGGLES_MAC` with `resolve_goggles_mac()`), so
// it can never be hardcoded and is never persisted across app launches --
// it is resolved fresh at the top of every `RNDISTransport` connect.
//
// This type is deliberately decoupled from libusb/RNDISTransport's actual
// I/O: `resolve(sendFrame:receiveFrame:log:)` takes plain closures instead
// of touching a device handle directly, so the retry/timeout/fallback
// LOGIC (the actual thing design §3.2 specifies precisely: 6 attempts x
// 500ms = 3s budget, gratuitous-ARP acceptance, multi-subnet sweep
// fallback) is unit-testable with an in-memory fake transport, without
// real hardware or even libusb linked into the test target's execution
// path. `RNDISTransport` supplies the real closures (synchronous
// `libusb_bulk_transfer` send/receive) at connect time.
// ─────────────────────────────────────────────────────────────────────────

/// Resolves the goggles' current RNDIS MAC address over an already-up
/// RNDIS link, per design §3.2's exact required procedure, with a
/// multi-subnet sweep fallback ported from the Python prototype's
/// `rndis_arp_sweep.py`.
public enum ARPResolver {

    // MARK: - Host/goggles addressing (design §3.2)

    /// The host's fixed identity on the RNDIS link for every ARP exchange.
    /// Not the goggles' MAC (which is what this type resolves) -- this one
    /// is fixed by design, matching the Python prototype's `HOST_MAC`.
    public static let hostMac = Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
    public static let hostIp = "192.168.60.1"
    /// The subnet address the goggles are expected to answer on. This is
    /// what gets ARP-resolved -- the goggles' MAC changes every reboot,
    /// but their IP on this link does not.
    public static let gogglesIp = "192.168.60.2"

    /// Design §3.2 steps 1-2: "Wait up to 500 ms for an ARP reply; retry
    /// up to 6 times (3 s budget)."
    public static let primaryAttempts = 6
    public static let primaryTimeout: TimeInterval = 0.5

    /// Multi-subnet sweep fallback candidates, ported verbatim from the
    /// Python prototype's `rndis_arp_sweep.py` (`SUBNETS`/`HOSTS_TO_TRY`).
    public static let sweepSubnets = [
        "192.168.60", "192.168.2", "192.168.1", "192.168.42", "192.168.0",
        "10.0.0", "10.1.1", "172.16.0",
    ]
    public static let sweepHosts: [Int] = Array(1...10) + [100, 200, 254]
    /// `rndis_arp_sweep.py` listens for 5s after blasting every probe.
    public static let sweepListenDuration: TimeInterval = 5.0

    public struct Result: Equatable {
        public let mac: Data
        /// Non-nil only when the primary 192.168.60.2 resolution
        /// exhausted its budget and the multi-subnet sweep answered
        /// instead -- purely diagnostic (design brief: "report whatever
        /// subnet answered as a diagnostic"), never silently swallowed.
        public let sweepDiagnostic: SweepDiagnostic?
    }

    public struct SweepDiagnostic: Equatable {
        public let subnet: String
        public let ip: String
    }

    public enum ARPResolverError: Error, CustomStringConvertible {
        /// Both the primary probe and the sweep fallback got no reply at
        /// all.
        case noReply

        public var description: String {
            "Could not ARP-resolve the goggles' RNDIS MAC: neither the primary probe at \(gogglesIp) nor the multi-subnet sweep fallback got any reply. Is Liveview-over-USB actually enabled/linked on the goggles?"
        }
    }

    /// Runs the full resolution procedure (design §3.2, steps 1-4).
    ///
    /// - Parameters:
    ///   - sendFrame: transmits one already-Ethernet-framed ARP packet
    ///     over the link. RNDIS-wrapping and the actual bulk-OUT write are
    ///     the caller's responsibility.
    ///   - receiveFrame: blocks for up to the given timeout for one
    ///     inbound Ethernet frame (already RNDIS-unwrapped), returning
    ///     `nil` if nothing arrived within that timeout. Called
    ///     repeatedly; each call should honor the timeout it's given
    ///     (this resolver already accounts for the 500ms-per-attempt /
    ///     6-attempt budget itself, so `receiveFrame` should not apply
    ///     its own extra retry loop).
    ///   - log: diagnostic sink, called once per failed primary attempt
    ///     and once with the sweep outcome (design §8.6: log
    ///     unknown/unexpected states rather than silently dropping them).
    ///     Defaults to a no-op for callers (e.g. tests) that don't care.
    public static func resolve(
        sendFrame: (Data) throws -> Void,
        receiveFrame: (TimeInterval) throws -> Data?,
        log: (String) -> Void = { _ in }
    ) throws -> Result {
        if let mac = try primaryResolve(sendFrame: sendFrame, receiveFrame: receiveFrame, log: log) {
            return Result(mac: mac, sweepDiagnostic: nil)
        }

        log(
            "Primary ARP resolution at \(gogglesIp) exhausted its "
                + "\(primaryAttempts)x\(Int(primaryTimeout * 1000))ms (3s) budget with no reply "
                + "-- falling back to the multi-subnet sweep."
        )

        if let sweep = try sweepResolve(sendFrame: sendFrame, receiveFrame: receiveFrame, log: log) {
            log(
                "Sweep fallback found a responder at \(sweep.ip) "
                    + "(subnet \(sweep.subnet).0/24) -- MAC \(sweep.mac.hexColonString()). "
                    + "This is off the expected \(gogglesIp)-hosting subnet; treating it as "
                    + "the goggles is a best-effort diagnostic fallback, not a confirmed match."
            )
            return Result(mac: sweep.mac, sweepDiagnostic: SweepDiagnostic(subnet: sweep.subnet, ip: sweep.ip))
        }

        throw ARPResolverError.noReply
    }

    // MARK: - Primary resolution (design §3.2 steps 1-3)

    /// Sends an ARP request for `gogglesIp` from `hostIp`/`hostMac`, waits
    /// up to `primaryTimeout` for a reply, and retries up to
    /// `primaryAttempts` times. Also accepts a gratuitous ARP or an ARP
    /// request originating from `gogglesIp` as a valid MAC source (step
    /// 3), in case the goggles announce themselves before being asked.
    static func primaryResolve(
        sendFrame: (Data) throws -> Void,
        receiveFrame: (TimeInterval) throws -> Data?,
        log: (String) -> Void
    ) throws -> Data? {
        for attempt in 1...primaryAttempts {
            let request = RawNet.buildARPRequest(srcMac: hostMac, srcIp: hostIp, targetIp: gogglesIp)
            try sendFrame(request)

            let deadline = Date().addingTimeInterval(primaryTimeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                guard let frame = try receiveFrame(remaining) else { break }
                guard let arp = RawNet.parseARP(frame) else { continue }
                // Step 3: any ARP traffic (reply OR request, gratuitous OR
                // not) whose SENDER is the goggles' IP teaches us its MAC
                // -- we don't require it to be specifically a reply to our
                // own request.
                if arp.senderIp == gogglesIp {
                    return arp.senderMac
                }
            }

            log("ARP attempt \(attempt)/\(primaryAttempts) at \(gogglesIp): no reply yet...")
        }
        return nil
    }

    // MARK: - Multi-subnet sweep fallback (rndis_arp_sweep.py)

    struct SweepResult {
        let mac: Data
        let subnet: String
        let ip: String
    }

    /// Design §3.2 step 4: only reached once the primary 3s budget is
    /// exhausted. Blasts an ARP "who-has" across every host in every
    /// candidate subnet (ported verbatim from `rndis_arp_sweep.py`), then
    /// listens for `sweepListenDuration` for any reply at all -- unlike
    /// the primary resolver, this doesn't require the sender to match a
    /// specific expected IP, since the whole point is "we don't know
    /// which subnet, if any, the goggles are actually on."
    static func sweepResolve(
        sendFrame: (Data) throws -> Void,
        receiveFrame: (TimeInterval) throws -> Data?,
        log: (String) -> Void
    ) throws -> SweepResult? {
        var targets: [(srcIp: String, targetIp: String)] = []
        for subnet in sweepSubnets {
            let srcIp = "\(subnet).1"
            for host in sweepHosts {
                targets.append((srcIp: srcIp, targetIp: "\(subnet).\(host)"))
            }
        }

        log("Sending \(targets.count) sweep ARP probes across \(sweepSubnets.count) candidate subnets...")
        for target in targets {
            let request = RawNet.buildARPRequest(srcMac: hostMac, srcIp: target.srcIp, targetIp: target.targetIp)
            // Best-effort per rndis_arp_sweep.py (a single dropped probe
            // isn't fatal to the sweep as a whole).
            try? sendFrame(request)
        }

        let deadline = Date().addingTimeInterval(sweepListenDuration)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let frame = try receiveFrame(remaining) else { continue }
            guard let arp = RawNet.parseARP(frame) else { continue }
            let subnetComponents = arp.senderIp.split(separator: ".").dropLast()
            let subnet = subnetComponents.joined(separator: ".")
            return SweepResult(mac: arp.senderMac, subnet: subnet, ip: arp.senderIp)
        }
        return nil
    }
}

extension Data {
    func hexColonString() -> String {
        map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
