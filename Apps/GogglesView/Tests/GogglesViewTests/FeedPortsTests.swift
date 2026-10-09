import Testing
import Foundation
@testable import GogglesView

@Suite struct FeedPortsTests {
    @Test func slotsAreLowestFreeAndStable() {
        var a = FeedSlotAllocator()
        #expect(a.assign("a") == 0)
        #expect(a.assign("b") == 1)
        #expect(a.assign("c") == 2)
        #expect(a.assign("b") == 1, "same device keeps its slot")
        a.release("a")
        #expect(a.assign("d") == 0, "a freed slot is reused")
        #expect(a.slot("c") == 2)
        #expect(a.slot("zzz") == nil)
    }

    @Test func firstWindowKeepsTheConfiguredPort() {
        #expect(FeedPorts.port(base: 9000, slot: 0) == 9000)
        #expect(FeedPorts.port(base: 9000, slot: 3) == 9003)
        #expect(FeedPorts.port(base: 9000, slot: 3, perFeed: false) == 9000)
    }

    @Test func portsNeverExceedTheRangeOrCollide() {
        let ports = (0..<4).map { FeedPorts.port(base: 65534, slot: $0) }
        #expect(ports.allSatisfy { (1...65535).contains($0) })
        #expect(Set(ports).count == ports.count)
    }

    @Test func ndiNamesAreUniquePerSlotAndShort() {
        #expect(FeedPorts.ndiName(base: "GogglesView", slot: 0) == "GogglesView")
        #expect(FeedPorts.ndiName(base: "GogglesView", slot: 1) == "GogglesView 2")
        #expect(FeedPorts.ndiName(base: "GogglesView", slot: 1, perFeed: false) == "GogglesView")
        let long = String(repeating: "x", count: 63)
        #expect(FeedPorts.ndiName(base: long, slot: 9).count <= 63)
    }

    @Test func srtListenerMakesObsCallIn() {
        let u = OBSFeedSources.url(proto: .srt, srtMode: .listener, latencyMs: 120, port: 9001, obsHost: "localhost")
        #expect(u == "srt://127.0.0.1:9001?mode=caller&latency=120000")
    }

    @Test func srtCallerMakesObsListen() {
        let u = OBSFeedSources.url(proto: .srt, srtMode: .caller, latencyMs: 200, port: 9002, obsHost: "127.0.0.1")
        #expect(u == "srt://0.0.0.0:9002?mode=listener&latency=200000")
    }

    @Test func udpMakesObsListen() {
        let u = OBSFeedSources.url(proto: .udp, srtMode: .caller, latencyMs: 120, port: 5001, obsHost: "127.0.0.1")
        #expect(u.hasPrefix("udp://0.0.0.0:5001"))
    }

    @Test func remoteObsGetsThisMacsHostName() {
        #expect(OBSFeedSources.gogglesHost(obsHost: "192.168.1.20") == ProcessInfo.processInfo.hostName)
        #expect(OBSFeedSources.gogglesHost(obsHost: " LocalHost ") == "127.0.0.1")
    }

    @Test func sourcesGetPortsPerSlotAndUniqueNames() {
        let s = OBSFeedSources.sources(
            feeds: [(name: "Runner 1", slot: 0), (name: "Runner 1", slot: 1), (name: "Feed 3", slot: 2)],
            proto: .srt, srtMode: .listener, latencyMs: 120, srtBase: 9000, udpBase: 5000, perFeed: true, obsHost: "127.0.0.1")
        #expect(s.map(\.name) == ["GogglesView Runner 1", "GogglesView Runner 1 (2)", "GogglesView Feed 3"])
        #expect(s.map { $0.url.components(separatedBy: ":")[2].prefix(4) }.map(String.init) == ["9000", "9001", "9002"])
        #expect(Set(s.map(\.name)).count == 3)
    }

    @Test func withoutPerFeedEveryFeedUsesTheSamePort() {
        let s = OBSFeedSources.sources(feeds: [(name: "A", slot: 0), (name: "B", slot: 1)], proto: .udp, srtMode: .listener,
                                       latencyMs: 120, srtBase: 9000, udpBase: 5000, perFeed: false, obsHost: "127.0.0.1")
        #expect(s[0].url == s[1].url)
    }

    @Test func inputSettingsCarryTheUrlAndNoSecrets() {
        let d = OBSFeedSources.inputSettings(url: "srt://127.0.0.1:9000?mode=caller")
        #expect(d["input"] as? String == "srt://127.0.0.1:9000?mode=caller")
        #expect(d["is_local_file"] as? Bool == false)
        #expect(!String(describing: d).lowercased().contains("passphrase"))
    }

    @Test func createInputRequestIsWellFormed() throws {
        let text = OBSProtocol.request(type: "CreateInput", id: "1", data: [
            "sceneName": "Scene", "inputName": "GogglesView A", "inputKind": "ffmpeg_source",
            "inputSettings": OBSFeedSources.inputSettings(url: "udp://0.0.0.0:5000"), "sceneItemEnabled": true])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let d = try #require(obj["d"] as? [String: Any])
        #expect(d["requestType"] as? String == "CreateInput")
        let rd = try #require(d["requestData"] as? [String: Any])
        #expect(rd["inputKind"] as? String == "ffmpeg_source")
    }
}
