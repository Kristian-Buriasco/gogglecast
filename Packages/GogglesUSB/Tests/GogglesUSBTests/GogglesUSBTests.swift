// Task 1.6: ARPResolver retry/timeout/fallback logic, exercised entirely
// against an in-memory fake link -- no real hardware/libusb involved. This
// is the "unit-testable in isolation" seam the task brief asked for: the
// resolution LOGIC (attempt/timeout accounting, gratuitous-ARP acceptance,
// sweep fallback) is fully decoupled from `RNDISTransport`'s actual USB
// I/O via `ARPResolver.resolve`'s injected `sendFrame`/`receiveFrame`
// closures.

import Testing
import Foundation
@testable import GogglesUSB
import GogglesProtocol

// MARK: - Fake link

/// A minimal in-memory stand-in for the RNDIS link, scripted per test:
/// `scriptedReplies[attemptIndex]` (0-based, counting every `sendFrame`
/// call across both the primary probe loop and the sweep) is returned by
/// the *next* `receiveFrame` call after that many sends have happened.
/// `nil` (or running off the end of the script) means "no reply" -- the
/// fake never actually blocks/sleeps, so a full 6-attempt primary failure
/// and even the multi-subnet sweep's send phase run near-instantly. (The
/// sweep's *listen* phase, when nothing ever answers, still burns its real
/// 5s `sweepListenDuration` window because `ARPResolver` polls `Date()`
/// directly -- deliberately not mocked out. Tests below avoid exercising
/// that specific total-failure path to stay fast; the timing constants
/// themselves are covered separately.)
final class FakeARPLink {
    private(set) var sentFrames: [Data] = []
    private var repliesByAttempt: [Int: [Data]]
    private var attemptIndex = 0

    /// `repliesByAttempt[n]` = frames "arriving" after the (0-based) nth
    /// `sendFrame` call, delivered in order on subsequent `receiveFrame`
    /// calls before the next send.
    init(repliesByAttempt: [Int: [Data]] = [:]) {
        self.repliesByAttempt = repliesByAttempt
    }

    private var pendingQueue: [Data] = []

    func sendFrame(_ frame: Data) throws {
        sentFrames.append(frame)
        pendingQueue.append(contentsOf: repliesByAttempt[attemptIndex] ?? [])
        attemptIndex += 1
    }

    func receiveFrame(_ timeout: TimeInterval) throws -> Data? {
        guard !pendingQueue.isEmpty else { return nil }
        return pendingQueue.removeFirst()
    }
}

// MARK: - Constants sanity

@Test func hostIdentityMatchesDesignSpec() {
    #expect(ARPResolver.hostMac == Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]))
    #expect(ARPResolver.hostIp == "192.168.60.1")
    #expect(ARPResolver.gogglesIp == "192.168.60.2")
}

@Test func retryScheduleMatchesDesignSpec() {
    // Design §3.2: "Wait up to 500 ms for an ARP reply; retry up to 6
    // times (3 s budget)."
    #expect(ARPResolver.primaryAttempts == 6)
    #expect(ARPResolver.primaryTimeout == 0.5)
    #expect(Double(ARPResolver.primaryAttempts) * ARPResolver.primaryTimeout == 3.0)
}

@Test func sweepSubnetsMatchPrototype() {
    // Ported verbatim from rndis_arp_sweep.py's SUBNETS/HOSTS_TO_TRY.
    #expect(ARPResolver.sweepSubnets == [
        "192.168.60", "192.168.2", "192.168.1", "192.168.42", "192.168.0",
        "10.0.0", "10.1.1", "172.16.0",
    ])
    #expect(ARPResolver.sweepHosts == Array(1...10) + [100, 200, 254])
}

// MARK: - Primary resolution

@Test func resolvesOnFirstAttemptViaOrdinaryReply() throws {
    let goggles = Data([0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33])
    let reply = RawNet.buildARPReply(
        srcMac: goggles, srcIp: ARPResolver.gogglesIp,
        dstMac: ARPResolver.hostMac, dstIp: ARPResolver.hostIp
    )
    let link = FakeARPLink(repliesByAttempt: [0: [reply]])

    let result = try ARPResolver.resolve(sendFrame: link.sendFrame, receiveFrame: link.receiveFrame)

    #expect(result.mac == goggles)
    #expect(result.sweepDiagnostic == nil)
    #expect(link.sentFrames.count == 1)
}

@Test func retriesUntilAReplyArrives() throws {
    let goggles = Data([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
    let reply = RawNet.buildARPReply(
        srcMac: goggles, srcIp: ARPResolver.gogglesIp,
        dstMac: ARPResolver.hostMac, dstIp: ARPResolver.hostIp
    )
    // No reply after attempts 0/1 (0-based) -- only after the 3rd send.
    let link = FakeARPLink(repliesByAttempt: [2: [reply]])

    let result = try ARPResolver.resolve(sendFrame: link.sendFrame, receiveFrame: link.receiveFrame)

    #expect(result.mac == goggles)
    #expect(link.sentFrames.count == 3)
}

@Test func acceptsGratuitousARPAsMacSource() throws {
    // A gratuitous ARP (op 1, sender == target == gogglesIp) arriving
    // unprompted, per design §3.2 step 3 ("Also accept a gratuitous ARP
    // ... as a source of the MAC").
    let goggles = Data([0x02, 0xDE, 0xAD, 0xBE, 0xEF, 0x01])
    // op is already 1 (request) from buildARPRequest; sender == target ==
    // gogglesIp is exactly the gratuitous-ARP shape.
    let gratuitous = RawNet.buildARPRequest(
        srcMac: goggles, srcIp: ARPResolver.gogglesIp, targetIp: ARPResolver.gogglesIp
    )
    let link = FakeARPLink(repliesByAttempt: [0: [gratuitous]])

    let result = try ARPResolver.resolve(sendFrame: link.sendFrame, receiveFrame: link.receiveFrame)

    #expect(result.mac == goggles)
}

@Test func acceptsARPRequestFromGogglesAsMacSource() throws {
    // Design §3.2 step 3: "an ARP request originating from 192.168.60.2"
    // (the goggles asking "who has X", not answering our probe).
    let goggles = Data([0x02, 0xCA, 0xFE, 0xBA, 0xBE, 0x02])
    let requestFromGoggles = RawNet.buildARPRequest(
        srcMac: goggles, srcIp: ARPResolver.gogglesIp, targetIp: ARPResolver.hostIp
    )
    let link = FakeARPLink(repliesByAttempt: [0: [requestFromGoggles]])

    let result = try ARPResolver.resolve(sendFrame: link.sendFrame, receiveFrame: link.receiveFrame)

    #expect(result.mac == goggles)
}

@Test func ignoresReplyFromUnrelatedIP() throws {
    // A reply whose sender IP is NOT the goggles' IP must not be accepted
    // -- resolution should keep retrying (and eventually fail, here, since
    // nothing else answers).
    let unrelated = RawNet.buildARPReply(
        srcMac: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]), srcIp: "192.168.60.99",
        dstMac: ARPResolver.hostMac, dstIp: ARPResolver.hostIp
    )
    let link = FakeARPLink(repliesByAttempt: [
        0: [unrelated], 1: [unrelated], 2: [unrelated],
        3: [unrelated], 4: [unrelated], 5: [unrelated],
    ])

    let mac = try? ARPResolver.primaryResolve(
        sendFrame: link.sendFrame, receiveFrame: link.receiveFrame, log: { _ in }
    )
    #expect(mac == nil)
    #expect(link.sentFrames.count == ARPResolver.primaryAttempts)
}

// MARK: - Sweep fallback

@Test func fallsBackToSweepWhenPrimaryExhausted() throws {
    // Primary gets nothing at all (6 fast no-op attempts); the sweep's
    // very first probe (send index 6, right after the 6 primary sends)
    // gets an immediate answer, so this test does not wait out the real
    // 5s sweepListenDuration window.
    let sweepResponder = Data([0x02, 0x99, 0x99, 0x99, 0x99, 0x99])
    let sweepReply = RawNet.buildARPReply(
        srcMac: sweepResponder, srcIp: "192.168.2.7",
        dstMac: ARPResolver.hostMac, dstIp: "192.168.2.1"
    )
    let link = FakeARPLink(repliesByAttempt: [ARPResolver.primaryAttempts: [sweepReply]])

    var logs: [String] = []
    let result = try ARPResolver.resolve(
        sendFrame: link.sendFrame, receiveFrame: link.receiveFrame, log: { logs.append($0) }
    )

    #expect(result.mac == sweepResponder)
    #expect(result.sweepDiagnostic == ARPResolver.SweepDiagnostic(subnet: "192.168.2", ip: "192.168.2.7"))
    #expect(logs.contains { $0.contains("falling back to the multi-subnet sweep") })
    #expect(logs.contains { $0.contains("192.168.2.7") })
}

@Test func sweepTargetsMatchExpectedCount() {
    // sweepSubnets.count * sweepHosts.count probes, matching
    // rndis_arp_sweep.py's nested-loop construction.
    let expectedCount = ARPResolver.sweepSubnets.count * ARPResolver.sweepHosts.count
    let link = FakeARPLink()
    _ = try? ARPResolver.sweepResolve(sendFrame: link.sendFrame, receiveFrame: { _ in nil }, log: { _ in })
    #expect(link.sentFrames.count == expectedCount)
}

// MARK: - No-reply-at-all error

@Test func throwsWhenSweepAlsoFindsNothing() throws {
    // Every send gets no reply at all, including every sweep probe -- the
    // resolver must surface a real error, not silently return a bogus
    // MAC. NOTE: this test genuinely waits out the real
    // `sweepListenDuration` (5s) window since `ARPResolver` polls
    // wall-clock `Date()` directly and nothing here is mocked at that
    // level -- kept as one deliberately-slow test rather than mocking the
    // clock, since the *value* of that constant is asserted elsewhere and
    // this test's job is the end-to-end "give up honestly" behavior.
    let link = FakeARPLink()
    #expect(throws: ARPResolver.ARPResolverError.self) {
        try ARPResolver.resolve(sendFrame: link.sendFrame, receiveFrame: link.receiveFrame)
    }
}
