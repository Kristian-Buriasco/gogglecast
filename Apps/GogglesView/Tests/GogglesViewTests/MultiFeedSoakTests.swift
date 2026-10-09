import Foundation
import Testing
@testable import GogglesView

// Soak test for events with several goggles on one Mac: N software goggles (`FakeGoggles`), each with
// its own decode session, a recording to disk and a UDP stream to loopback, all at once.
//
// Off by default (it takes minutes). Run it with, for example:
//   GOGGLES_SOAK_FEEDS=6 GOGGLES_SOAK_SECONDS=600 swift test --filter MultiFeedSoak
// It prints one line per sample and a summary, and fails when a feed stops decoding or memory keeps
// growing after warm-up.

private let env = ProcessInfo.processInfo.environment
private let soakFeeds = Int(env["GOGGLES_SOAK_FEEDS"] ?? "") ?? 0
private let soakSeconds = Int(env["GOGGLES_SOAK_SECONDS"] ?? "") ?? 120
/// One encoder feeds every session (the default): the app does N decodes, recordings and streams, which is the
/// load that matters. GOGGLES_SOAK_SHARED=0 gives each session its own software goggles, but then the Mac's
/// video encoder, not GogglesView, limits the frame rate.
/// What each feed also does besides decoding: "all" (default), "rec", "net" or "none". For narrowing down a limit.
private let soakOutputs = env["GOGGLES_SOAK_OUTPUTS"] ?? "all"
/// GOGGLES_SOAK_REENCODE=0 turns the re-encode stage off (Settings > Streaming), so recordings and streams take the
/// goggles' own stream instead of a per-window VideoToolbox re-encode.
private let soakReencode = env["GOGGLES_SOAK_REENCODE"] != "0"
/// GOGGLES_SOAK_HALF=1 re-encodes at 30 fps (Settings > Streaming).
private let soakHalf = env["GOGGLES_SOAK_HALF"] == "1"
private let soakShared = env["GOGGLES_SOAK_SHARED"] != "0"

/// Pure pass/fail rules, tested separately so the soak thresholds are not a mystery.
enum SoakVerdict {
    /// A feed is stalled when its decoded-frame counter did not move over the window.
    static func stalledFeeds(previous: [UInt64], current: [UInt64]) -> [Int] {
        zip(previous, current).enumerated().filter { $0.element.1 <= $0.element.0 }.map(\.offset)
    }

    /// Footprint growth per feed per minute (MB), by a least-squares line over the samples.
    static func growthMBPerMinute(samplesMB: [Double], intervalSeconds: Double) -> Double {
        let n = Double(samplesMB.count)
        guard n >= 3 else { return 0 }
        let xs = (0..<samplesMB.count).map { Double($0) * intervalSeconds / 60 }
        let mx = xs.reduce(0, +) / n, my = samplesMB.reduce(0, +) / n
        let num = zip(xs, samplesMB).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        return den == 0 ? 0 : num / den
    }

    /// Leak guard: after warm-up, more than 2 MB per minute per feed is a leak, not noise.
    static func leaks(growthMBPerMinute: Double, feeds: Int) -> Bool { growthMBPerMinute > 2 * Double(max(feeds, 1)) }
}

@Suite struct SoakVerdictTests {
    @Test func stalledFeedsAreFound() {
        #expect(SoakVerdict.stalledFeeds(previous: [10, 20, 30], current: [15, 20, 31]) == [1])
        #expect(SoakVerdict.stalledFeeds(previous: [1], current: [2]).isEmpty)
    }

    @Test func growthSlopeIsMeasured() {
        let flat = SoakVerdict.growthMBPerMinute(samplesMB: [500, 501, 500, 500, 501], intervalSeconds: 30)
        #expect(abs(flat) < 1)
        let rising = SoakVerdict.growthMBPerMinute(samplesMB: [500, 530, 560, 590, 620], intervalSeconds: 30)
        #expect(abs(rising - 60) < 0.01)
        #expect(SoakVerdict.growthMBPerMinute(samplesMB: [1, 2], intervalSeconds: 30) == 0)
    }

    @Test func leakThresholdScalesWithFeeds() {
        #expect(!SoakVerdict.leaks(growthMBPerMinute: 6, feeds: 4))
        #expect(SoakVerdict.leaks(growthMBPerMinute: 20, feeds: 4))
    }
}

@Suite(.serialized, .enabled(if: soakFeeds > 0, "set GOGGLES_SOAK_FEEDS to run"))
struct MultiFeedSoakTests {
    @Test(.timeLimit(.minutes(120)))
    func severalFeedsDecodeRecordAndStreamTogether() async throws {
        let savedReencode = UserDefaults.standard.object(forKey: ReencodePrefs.enabledKey)
        UserDefaults.standard.set(soakReencode, forKey: ReencodePrefs.enabledKey)
        UserDefaults.standard.set(soakHalf, forKey: ReencodePrefs.halfRateKey)
        defer { UserDefaults.standard.removeObject(forKey: ReencodePrefs.halfRateKey) }
        defer {
            if let savedReencode { UserDefaults.standard.set(savedReencode, forKey: ReencodePrefs.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: ReencodePrefs.enabledKey) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var rigs: [(session: DecodeSession, fake: FakeGoggles, rec: Recorder, net: NetworkStreamer)] = []
        var sharedFake: FakeGoggles?
        for i in 0..<soakFeeds {
            let session = DecodeSession()
            let fake: FakeGoggles
            if soakShared, let first = sharedFake { first.joinLate(session); fake = first }
            else { fake = FakeGoggles(session: session, options: .init()); if soakShared { sharedFake = fake } }
            let rec = Recorder()
            let net = NetworkStreamer()
            if soakOutputs == "all" || soakOutputs == "rec" {
                try rec.start(to: dir.appendingPathComponent("feed\(i + 1).mov"))
                session.addKeyframeSafeConsumer(rec)
            }
            if soakOutputs == "all" || soakOutputs == "net" {
                session.addKeyframeSafeConsumer(net)
                net.start(host: "127.0.0.1", port: FeedPorts.port(base: 45000, slot: i))
            }
            if !soakShared || i == 0 { /* started below, after every session has joined */ }
            rigs.append((session, fake, rec, net))
        }
        var started = Set<ObjectIdentifier>()
        for r in rigs where started.insert(ObjectIdentifier(r.fake)).inserted { try r.fake.start() }
        defer { for r in rigs { r.fake.stop(); r.session.removeConsumer(r.rec); r.session.removeConsumer(r.net); r.net.stop(); r.rec.stop() } }

        let interval = 15.0
        let samples = max(4, Int(Double(soakSeconds) / interval))
        var footprints: [Double] = []
        var last = rigs.map { $0.session.decodedSequence() }
        let cpu0 = ProcessSampler.cpuTimeNs()
        let t0 = Date()
        print("soak: \(soakFeeds) feeds (\(soakShared ? "one shared source" : "separate sources"), re-encode \(soakReencode ? "on" : "off")), \(soakSeconds) s, sampling every \(Int(interval)) s")

        for n in 1...samples {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let now = rigs.map { $0.session.decodedSequence() }
            let stalled = SoakVerdict.stalledFeeds(previous: last, current: now)
            last = now
            let mb = Double(ProcessSampler.footprintBytes() ?? 0) / 1_048_576
            footprints.append(mb)
            let bytes = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
            let cpu = Double(ProcessSampler.cpuTimeNs() - cpu0) / 1e9 / Date().timeIntervalSince(t0) * 100
            print(String(format: "soak %3d/%d  mem %.0f MB  cpu %.0f%%  disk %.0f MB  decoded %@  delivered %@  stalled %@",
                         n, samples, mb, cpu, Double(bytes) / 1_048_576, now.map(String.init).joined(separator: "/"), rigs.map { String($0.fake.framesDelivered) }.joined(separator: "/"), stalled.map { String($0 + 1) }.joined(separator: ",")))
            #expect(stalled.isEmpty, "feeds \(stalled.map { $0 + 1 }) stopped decoding at sample \(n)")
        }

        // Ignore the first quarter: encoders, pools and caches fill up first.
        let tail = Array(footprints.dropFirst(footprints.count / 4))
        let growth = SoakVerdict.growthMBPerMinute(samplesMB: tail, intervalSeconds: interval)
        print(String(format: "soak summary: memory growth %.1f MB/min after warm-up, %d feeds", growth, soakFeeds))
        #expect(!SoakVerdict.leaks(growthMBPerMinute: growth, feeds: soakFeeds), "memory grows \(growth) MB/min")
        for (i, r) in rigs.enumerated() {
            if soakOutputs == "all" || soakOutputs == "rec" { #expect(r.rec.isRecording, "feed \(i + 1) stopped recording") }
            #expect(r.fake.framesDelivered > 0)
        }
    }
}
