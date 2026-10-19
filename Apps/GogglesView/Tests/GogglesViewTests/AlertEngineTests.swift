import Foundation
import Testing
@testable import GogglesView

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private func cond(_ k: AlertKind, feed: String = "dev-123", name: String = "Pilot cam", detail: String = "") -> AlertCondition {
    AlertCondition(key: AlertKey(kind: k, feedID: feed, detail: detail), name: name)
}

private func cfg(away: Bool = true, delay: Int = 10, repeatMin: Int = 2) -> AlertConfig {
    var c = AlertConfig()
    c.away = away; c.repeatMinutes = repeatMin
    for k in AlertKind.allCases { c.settings[k]?.delay = delay }
    return c
}

private final class Eng {
    var engine = AlertEngine()
    func update(_ a: [AlertCondition], config: AlertConfig, now: Date) -> [AlertMessage] { engine.update(a, config: config, now: now) }
    func forget(feedID: String) { engine.forget(feedID: feedID) }
    var trackedCount: Int { engine.trackedCount }
}
private final class Inp {
    var inputs = AlertInputs()
    func conditions(feeds: [AlertFeed], helperDown: Bool, missingPrograms: [String], now: Date) -> (conditions: [AlertCondition], gone: [String]) {
        inputs.conditions(feeds: feeds, helperDown: helperDown, missingPrograms: missingPrograms, now: now)
    }
}

struct AlertEngineTests {
    @Test func alertsOnlyAfterTheDelay() {
        let e = Eng()
        #expect(e.update([cond(.signalLost)], config: cfg(), now: at(0)).isEmpty)
        #expect(e.update([cond(.signalLost)], config: cfg(), now: at(9)).isEmpty)
        let m = e.update([cond(.signalLost)], config: cfg(), now: at(10))
        #expect(m.count == 1)
        #expect(m[0].priority == 5)
        #expect(m[0].body.contains("Pilot cam"))
    }

    @Test func dedupesUntilCleared() {
        let e = Eng()
        _ = e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(0))
        for s in stride(from: 1.0, to: 100, by: 1) { #expect(e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(s)).isEmpty) }
    }

    @Test func recoveryAfterHoldIsDefaultPriority() {
        let e = Eng()
        _ = e.update([cond(.outputFailed, detail: "SRT")], config: cfg(delay: 0), now: at(0))
        #expect(e.update([], config: cfg(), now: at(1)).isEmpty)            // hold not over
        let m = e.update([], config: cfg(), now: at(7))
        #expect(m.count == 1 && m[0].isRecovery && m[0].priority == 3)
        #expect(m[0].body.contains("Pilot cam / SRT"))
        #expect(e.trackedCount == 0)
    }

    @Test func flappingBeforeDelaySendsNothing() {
        let e = Eng()
        var sent = 0
        for i in 0..<40 {   // 4 s down, 4 s up, delay 10 s
            let down = (i / 4) % 2 == 0
            sent += e.update(down ? [cond(.signalLost)] : [], config: cfg(), now: at(TimeInterval(i))).count
        }
        #expect(sent == 0)
    }

    @Test func flappingAfterAlertSendsNoRecoveryOrSecondAlert() {
        let e = Eng()
        _ = e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(0))
        // gone for 2 s (< recovery hold), back again
        #expect(e.update([], config: cfg(), now: at(1)).isEmpty)
        #expect(e.update([], config: cfg(), now: at(3)).isEmpty)
        #expect(e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(4)).isEmpty)
    }

    @Test func repeatsEveryIntervalAndStopsAtTheCap() {
        let e = Eng()
        var c = cfg(delay: 0, repeatMin: 2); c.maxRepeats = 10
        var count = 0
        for s in stride(from: 0.0, through: 3600, by: 10) { count += e.update([cond(.batteryCritical)], config: c, now: at(s)).count }
        #expect(count == 11)   // first alert + 10 reminders
    }

    @Test func noRepeatWhenIntervalIsZero() {
        let e = Eng()
        var count = 0
        for s in stride(from: 0.0, through: 1000, by: 10) { count += e.update([cond(.pictureFrozen)], config: cfg(delay: 0, repeatMin: 0), now: at(s)).count }
        #expect(count == 1)
    }

    @Test func nothingSentWhileAwayModeOff() {
        let e = Eng()
        for s in 0..<30 { #expect(e.update([cond(.signalLost)], config: cfg(away: false, delay: 0), now: at(TimeInterval(s))).isEmpty) }
        #expect(e.trackedCount == 0)
    }

    @Test func turningAwayOnStartsFresh() {
        let e = Eng()
        _ = e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(0))
        _ = e.update([cond(.signalLost)], config: cfg(away: false), now: at(1))
        #expect(e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(2)).count == 1)
    }

    @Test func disabledKindNeverSends() {
        let e = Eng()
        var c = cfg(delay: 0); c.settings[.signalLost]?.enabled = false
        #expect(e.update([cond(.signalLost)], config: c, now: at(0)).isEmpty)
    }

    @Test func criticalBatterySupersedesLowWithoutExtraMessages() {
        let e = Eng()
        let c = cfg(delay: 0)
        #expect(e.update([cond(.batteryLow)], config: c, now: at(0)).count == 1)
        let m = e.update([cond(.batteryCritical)], config: c, now: at(1))
        #expect(m.count == 1 && m[0].title.contains(AlertKind.batteryCritical.title))
        #expect(e.update([cond(.batteryCritical)], config: c, now: at(20)).isEmpty)   // low is not "recovered"
    }

    @Test func eachFeedAndOutputAlertsOnce() {
        let e = Eng()
        let conds = [cond(.outputFailed, feed: "a", name: "Feed 1", detail: "SRT"), cond(.outputFailed, feed: "a", name: "Feed 1", detail: "RTMP"),
                     cond(.outputFailed, feed: "b", name: "Feed 2", detail: "SRT")]
        #expect(e.update(conds, config: cfg(delay: 0), now: at(0)).count == 3)
        #expect(e.update(conds, config: cfg(delay: 0), now: at(1)).isEmpty)
    }

    @Test func forgetDropsAClosedFeedSilently() {
        let e = Eng()
        _ = e.update([cond(.signalLost)], config: cfg(delay: 0), now: at(0))
        e.forget(feedID: "dev-123")
        #expect(e.update([], config: cfg(), now: at(30)).isEmpty)
    }

    @Test func defaultPrioritiesAndStoredOverrides() {
        #expect(AlertKind.signalLost.defaultPriority == 5 && AlertKind.outputFailed.defaultPriority == 5)
        #expect(AlertKind.batteryCritical.defaultPriority == 4 && AlertKind.pictureFrozen.defaultPriority == 4)
        #expect(AlertKind.batteryLow.defaultPriority == 3 && AlertKind.outputStalled.defaultPriority == 3)
        let d = UserDefaults(suiteName: "AlertPrefsTests-\(UUID().uuidString)")!
        #expect(AlertPrefs.config(d).away == false)
        d.set(true, forKey: AlertPrefs.awayKey); d.set(9, forKey: AlertPrefs.priorityKey(.batteryLow)); d.set(99, forKey: AlertPrefs.repeatKey)
        let c = AlertPrefs.config(d)
        #expect(c.away && c.setting(.batteryLow).priority == 5 && c.repeatMinutes == 60)
    }
}


struct AlertInputsTests {
    private func feed(_ live: Bool, issues: [FeedIssue] = [], outputs: [OutputChip] = []) -> AlertFeed {
        AlertFeed(id: "dev-123", name: "Pilot cam", isLive: live, issues: issues, outputs: outputs)
    }

    @Test func signalLostUsesTheDebounceAndNeverFiresForAFeedThatWasNeverLive() {
        let i = Inp()
        #expect(i.conditions(feeds: [feed(false)], helperDown: false, missingPrograms: [], now: at(0)).conditions.isEmpty)
        #expect(i.conditions(feeds: [feed(false)], helperDown: false, missingPrograms: [], now: at(10)).conditions.isEmpty)
        _ = i.conditions(feeds: [feed(true)], helperDown: false, missingPrograms: [], now: at(11))
        _ = i.conditions(feeds: [feed(true)], helperDown: false, missingPrograms: [], now: at(15))   // announced live
        _ = i.conditions(feeds: [feed(false)], helperDown: false, missingPrograms: [], now: at(16))
        #expect(i.conditions(feeds: [feed(false)], helperDown: false, missingPrograms: [], now: at(17)).conditions.isEmpty)   // < 3 s
        let r = i.conditions(feeds: [feed(false)], helperDown: false, missingPrograms: [], now: at(20))
        #expect(r.conditions.map(\.key.kind) == [.signalLost])
    }

    @Test func mapsIssuesOutputsHelperAndMissingDisplay() {
        let i = Inp()
        let f = feed(true, issues: [.criticalBattery(5), .frozenPicture, .blackPicture],
                     outputs: [OutputChip(name: "SRT", state: .error), OutputChip(name: "RTMP", state: .waiting), OutputChip(name: "NDI", state: .on)])
        let r = i.conditions(feeds: [f], helperDown: true, missingPrograms: ["Program output 1"], now: at(0))
        let kinds = r.conditions.map(\.key.kind)
        #expect(Set(kinds) == [.batteryCritical, .pictureFrozen, .pictureBlack, .outputFailed, .outputStalled, .helperNotResponding])
        #expect(kinds.filter { $0 == .outputFailed }.count == 2)
    }

    @Test func messagesNeverContainTheDeviceId() {
        let i = Inp(), e = Eng()
        let r = i.conditions(feeds: [feed(true, issues: [.frozenPicture])], helperDown: false, missingPrograms: [], now: at(0))
        let m = e.update(r.conditions, config: cfg(delay: 0), now: at(0))
        #expect(m.count == 1)
        #expect(!(m[0].body + m[0].title).contains("dev-123"))
    }

    @Test func closedFeedIsReportedGone() {
        let i = Inp()
        _ = i.conditions(feeds: [feed(true)], helperDown: false, missingPrograms: [], now: at(0))
        #expect(i.conditions(feeds: [], helperDown: false, missingPrograms: [], now: at(1)).gone == ["dev-123"])
    }
}

struct NtfyRequestTests {
    private let msg = AlertMessage(title: "GogglesView: Signal lost", body: "Pilot cam: Signal lost", priority: 5, tags: "rotating_light", isRecovery: false)

    @Test func buildsUrlHeadersAndBody() throws {
        let r = try #require(NtfyRequest.make(server: " https://ntfy.example.com/ ", topic: "race-1", message: msg, token: "tk_abc"))
        #expect(r.url?.absoluteString == "https://ntfy.example.com/race-1")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Title") == "GogglesView: Signal lost")
        #expect(r.value(forHTTPHeaderField: "Priority") == "5")
        #expect(r.value(forHTTPHeaderField: "Tags") == "rotating_light")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
        #expect(String(decoding: r.httpBody ?? Data(), as: UTF8.self) == "Pilot cam: Signal lost")
        #expect(r.timeoutInterval == 8)
    }

    @Test func noAuthHeaderWithoutToken() throws {
        let r = try #require(NtfyRequest.make(server: "http://10.0.0.5:8080", topic: "t", message: msg, token: "  "))
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func validation() {
        #expect(NtfyRequest.url(server: "ftp://x.com", topic: "t") == nil)
        #expect(NtfyRequest.url(server: "https://", topic: "t") == nil)
        #expect(NtfyRequest.url(server: "not a url", topic: "t") == nil)
        #expect(NtfyRequest.url(server: "https://x.com", topic: "") == nil)
        #expect(NtfyRequest.url(server: "https://x.com", topic: "a/b") == nil)
        #expect(NtfyRequest.url(server: "https://x.com", topic: "a b") == nil)
        #expect(NtfyRequest.url(server: "https://x.com", topic: String(repeating: "a", count: 65)) == nil)
        #expect(NtfyRequest.heartbeat("https://hc-ping.com/abc") != nil)
        #expect(NtfyRequest.heartbeat("javascript:alert(1)") == nil)
    }

    @Test func headersAreAsciiOnOneLine() {
        #expect(NtfyRequest.headerSafe("Café\nbatterie 日本") == "Cafebatterie")
        #expect(NtfyRequest.headerSafe("Café déjà") == "Cafe deja")
    }
}

/// Fake transport: no network.
private final class Fake: @unchecked Sendable {
    let lock = NSLock()
    var codes: [Int?]
    var requests: [URLRequest] = []
    var sleeps: [TimeInterval] = []
    init(_ codes: [Int?]) { self.codes = codes }
    var transport: AlertTransport { { [self] r in lock.withLock { requests.append(r); return codes.isEmpty ? nil : codes.removeFirst() } } }
    var sleep: @Sendable (TimeInterval) async -> Void { { [self] s in lock.withLock { sleeps.append(s) } } }
}

struct NtfySenderTests {
    private let req = URLRequest(url: URL(string: "https://x.example/t")!)

    @Test func retriesThreeTimesWithBackoffThenFails() async {
        let f = Fake([nil, 500, 503, nil])
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { "" })
        #expect(await s.deliver(req) == false)
        #expect(f.requests.count == 4 && f.sleeps == [1, 2, 4])
    }

    @Test func succeedsOnARetry() async {
        let f = Fake([nil, 200])
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { "" })
        #expect(await s.deliver(req))
        #expect(f.requests.count == 2)
    }

    @Test func clientErrorIsFinal() async {
        let f = Fake([401])
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { "" })
        #expect(await s.deliver(req) == false)
        #expect(f.requests.count == 1)
    }

    @Test func sendUsesTheTokenOnlyWhenSending() async {
        let f = Fake([200])
        let reads = Counter()
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { reads.bump(); return "tk" })
        #expect(reads.value == 0)
        let ok = await withCheckedContinuation { c in
            s.send(AlertMessage(title: "t", body: "b", priority: 3, tags: "x", isRecovery: false), server: "https://x.example", topic: "t") { c.resume(returning: $0) }
        }
        #expect(ok && reads.value == 1)
        #expect(f.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tk")
    }

    @Test func invalidServerSendsNothing() async {
        let f = Fake([200])
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { "" })
        let ok = await withCheckedContinuation { c in
            s.send(AlertMessage(title: "t", body: "b", priority: 3, tags: "x", isRecovery: false), server: "", topic: "t") { c.resume(returning: $0) }
        }
        #expect(!ok && f.requests.isEmpty)
    }

    @Test func heartbeatEvery30SecondsOnlyWhileAway() {
        let h = Hb()
        #expect(!h.due(away: false, urlValid: true, now: at(0)))
        #expect(h.due(away: true, urlValid: true, now: at(1)))
        #expect(!h.due(away: true, urlValid: true, now: at(20)))
        #expect(h.due(away: true, urlValid: true, now: at(31)))
        #expect(!h.due(away: true, urlValid: false, now: at(100)))
    }

    @Test func pingReportsStatus() async {
        let f = Fake([200])
        let s = NtfySender(transport: f.transport, sleep: f.sleep, token: { "" })
        let ok = await withCheckedContinuation { c in s.ping("https://hc-ping.com/x") { c.resume(returning: $0) } }
        #expect(ok)
    }
}

private final class Hb {
    var s = HeartbeatSchedule()
    func due(away: Bool, urlValid: Bool, now: Date) -> Bool { s.due(away: away, urlValid: urlValid, now: now) }
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func bump() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
}

// Joins SecretStoreTests' serialized suite: the backend is process-global.
private final class ReadCounter: SecretStore.Backend {
    var reads = 0
    func read(_ key: String) -> String? { reads += 1; return nil }
    func write(_ value: String, _ key: String) -> Bool { true }
    func remove(_ key: String) {}
}

extension SecretStoreTests {
    private func alertFixture() -> (ReadCounter, UserDefaults, Fake) {
        let b = ReadCounter()
        SecretStore.backend = b
        let d = UserDefaults(suiteName: "AlertCenterTests-\(UUID().uuidString)")!
        SecretStore.defaults = d
        return (b, d, Fake([200]))
    }

    @Test func alertCenterAtStartupAndWhileDisabledReadsNoKeychainAndSendsNothing() {
        let (b, d, f) = alertFixture()
        let c = AlertCenter(sender: NtfySender(transport: f.transport, sleep: f.sleep), defaults: d)
        let feeds = [AlertFeed(id: "a", name: "Feed 1", isLive: false, issues: [.frozenPicture], outputs: [OutputChip(name: "SRT", state: .error)])]
        c.update(feeds: feeds, helperDown: true, missingPrograms: ["Program output 1"])        // nothing configured
        d.set("https://ntfy.example.com", forKey: AlertPrefs.serverKey); d.set("race", forKey: AlertPrefs.topicKey)
        c.update(feeds: feeds, helperDown: true, missingPrograms: [])                          // configured, Away off
        #expect(b.reads == 0)
        #expect(f.requests.isEmpty)
    }

    @Test func tokenIsReadOnlyWhenAMessageIsSent() async {
        let (b, d, f) = alertFixture()
        d.set(true, forKey: AlertPrefs.awayKey)
        d.set("https://ntfy.example.com", forKey: AlertPrefs.serverKey); d.set("race", forKey: AlertPrefs.topicKey)
        d.set(0, forKey: AlertPrefs.delayKey(.pictureFrozen))
        let c = AlertCenter(sender: NtfySender(transport: f.transport, sleep: f.sleep), defaults: d)
        c.update(feeds: [], helperDown: false, missingPrograms: [])
        #expect(b.reads == 0)                                                                  // Away on, nothing wrong: still no read
        c.update(feeds: [AlertFeed(id: "a", name: "Feed 1", isLive: true, issues: [.frozenPicture], outputs: [])], helperDown: false, missingPrograms: [])
        for _ in 0..<200 where f.requests.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(f.requests.count == 1 && b.reads >= 1)
        #expect(f.requests[0].value(forHTTPHeaderField: "Priority") == "4")
    }
}
