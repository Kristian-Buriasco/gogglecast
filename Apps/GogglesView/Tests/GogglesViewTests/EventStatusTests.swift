import CoreVideo
import Foundation
import Testing
@testable import GogglesView

@Suite struct EventStatusTests {
    // MARK: rules

    @Test func batteryThresholds() {
        #expect(EventRules.batteryIssue(nil) == nil)
        #expect(EventRules.batteryIssue(80) == nil)
        #expect(EventRules.batteryIssue(25) == nil)
        #expect(EventRules.batteryIssue(24) == .lowBattery(24))
        #expect(EventRules.batteryIssue(10) == .lowBattery(10))
        #expect(EventRules.batteryIssue(9) == .criticalBattery(9))
    }

    @Test func combineTakesTheWorseOfConnectionAndIssues() {
        #expect(EventRules.combine(connection: .good, issues: []) == .good)
        #expect(EventRules.combine(connection: .good, issues: [.frozenPicture]) == .warning)
        #expect(EventRules.combine(connection: .good, issues: [.lowBattery(20), .criticalBattery(5)]) == .bad)
        #expect(EventRules.combine(connection: .bad, issues: [.frozenPicture]) == .bad)
    }

    @Test func pictureProblemsNeverTurnAFeedRed() {
        #expect(FeedIssue.blackPicture.severity == .warning)
        #expect(FeedIssue.frozenPicture.severity == .warning)
    }

    @Test func aLostFeedHasNoPictureOrBatteryIssues() {
        #expect(EventRules.issues(live: false, battery: 3, picture: .black).isEmpty)
        #expect(EventRules.issues(live: true, battery: 3, picture: .black) == [.criticalBattery(3), .blackPicture])
        #expect(EventRules.issues(live: true, battery: 90, picture: .unknown).isEmpty)
    }

    // MARK: picture watch

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func s(_ luma: Double, _ sig: UInt64) -> PictureWatch.Sample { .init(luma: luma, signature: sig) }

    @Test func blackAfterTenSecondsOfDarkness() {
        var w = PictureWatch()
        var seq: UInt64 = 0
        var state = PictureState.unknown
        for i in stride(from: 0, through: 12, by: 2) {
            seq += 100
            state = w.observe(s(2, UInt64(i)), sequence: seq, now: t0.addingTimeInterval(Double(i)))
            if i < 10 { #expect(state == .ok, "second \(i)") }
        }
        #expect(state == .black)
        #expect(w.observe(s(90, 99), sequence: seq + 100, now: t0.addingTimeInterval(14)) == .ok, "recovers when the picture is back")
    }

    @Test func frozenOnlyWhenTheSamePictureRepeatsWhileFramesKeepArriving() {
        var w = PictureWatch()
        var seq: UInt64 = 0
        var state = PictureState.unknown
        for i in stride(from: 0, through: 18, by: 2) {
            seq += 120
            state = w.observe(s(100, 777), sequence: seq, now: t0.addingTimeInterval(Double(i)))
        }
        #expect(state == .frozen)
        var stalled = PictureWatch()
        for i in stride(from: 0, through: 30, by: 2) {
            state = stalled.observe(s(100, 777), sequence: 500, now: t0.addingTimeInterval(Double(i)))
        }
        #expect(state == .ok, "a counter that stands still is a stalled stream, reported by the connection state")
    }

    @Test func aChangingPictureIsNeverFrozen() {
        var w = PictureWatch()
        var state = PictureState.unknown
        for i in 0..<20 { state = w.observe(s(100, UInt64(i)), sequence: UInt64(i * 100), now: t0.addingTimeInterval(Double(i * 2))) }
        #expect(state == .ok)
    }

    @Test func noSampleResetsTheWatch() {
        var w = PictureWatch()
        _ = w.observe(s(1, 1), sequence: 1, now: t0)
        #expect(w.observe(nil, sequence: 2, now: t0.addingTimeInterval(20)) == .unknown)
        #expect(w.observe(s(1, 1), sequence: 3, now: t0.addingTimeInterval(21)) == .ok, "the dark timer starts over")
    }

    private func buffer(format: OSType, width: Int = 320, height: Int = 180, fill: (UnsafeMutableRawPointer, Int, Int) -> Void) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        fill(CVPixelBufferGetBaseAddressOfPlane(b, 0)!, CVPixelBufferGetBytesPerRowOfPlane(b, 0), CVPixelBufferGetHeightOfPlane(b, 0))
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    @Test func sampleReadsTheLumaOfAnEightBitBuffer() throws {
        let dark = buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { p, stride, h in memset(p, 0, stride * h) }
        let grey = buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { p, stride, h in memset(p, 200, stride * h) }
        let a = try #require(PictureWatch.sample(dark)), b = try #require(PictureWatch.sample(grey))
        #expect(a.luma == 0)
        #expect(abs(b.luma - 200) < 0.001)
        #expect(a.signature != b.signature)
        #expect(PictureWatch.sample(grey) == b, "same picture, same sample")
    }

    @Test func sampleReadsTheHighByteOfATenBitBuffer() throws {
        let mid = buffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) { p, stride, h in
            let words = p.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(stride * h / 2) { words[i] = 0x8000 }  // 10-bit value 512, left-aligned
        }
        #expect(abs(try #require(PictureWatch.sample(mid)).luma - 128) < 0.001)
    }

    @Test func sampleIgnoresFormatsItDoesNotKnow() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        #expect(PictureWatch.sample(pb!) == nil)
    }

    // MARK: outputs, icon, names

    @Test func outputKindsDefaultToSRTOnly() {
        let d = UserDefaults(suiteName: "eo-\(UUID().uuidString)")!
        #expect(EventOutputKind.enabled(.srt, d))
        #expect(!EventOutputKind.enabled(.udp, d))
        #expect(!EventOutputKind.enabled(.ndi, d))
        d.set(true, forKey: EventOutputKind.udp.prefKey)
        #expect(EventOutputKind.enabled(.udp, d))
    }

    @Test func outputSummaryMarksWaitingAndFailedOutputs() {
        #expect(OverviewLogic.outputSummary([.init(name: "SRT", state: .off), .init(name: "UDP", state: .off)]) == "-")
        #expect(OverviewLogic.outputSummary([.init(name: "SRT", state: .on), .init(name: "UDP", state: .waiting), .init(name: "NDI", state: .error)]) == "SRT (UDP) NDI!")
    }

    @Test func aWindowWithNothingRunningShowsEveryOutputOff() {
        let session = NSObject()
        let chips = SessionControlBoard.shared.outputChips(for: session)
        #expect(chips.map(\.name) == ["SRT", "UDP", "NDI"])
        #expect(chips.allSatisfy { $0.state == .off })
        SessionControlBoard.shared.register(srt: SRTOutput(), for: session)
        #expect(SessionControlBoard.shared.outputChips(for: session).allSatisfy { $0.state == .off })
    }

    @Test func menuBarIconFollowsTheEventStatus() {
        let live = [GogglesUIStateKind.live, .live]
        #expect(MenuBarController.summaryCategory(live, status: nil) == .live)
        #expect(MenuBarController.summaryCategory(live, status: .good) == .live)
        #expect(MenuBarController.summaryCategory(live, status: .warning) == .waiting)
        #expect(MenuBarController.summaryCategory(live, status: .bad) == .error)
        #expect(MenuBarController.summaryCategory([.live, .noDevice], status: .good) == .error)
    }

    @Test func alertsUseTheCrewNameWhenThereIsOne() {
        #expect(ProgramFeedNaming.displayName(deviceId: "a", fallback: "Goggles 3 (…12)", custom: ["a": "  Runner 3 "]) == "Runner 3")
        #expect(ProgramFeedNaming.displayName(deviceId: "b", fallback: "Goggles 3 (…12)", custom: ["a": "Runner 3"]) == "Goggles 3 (…12)")
        #expect(ProgramFeedNaming.displayName(deviceId: "a", fallback: "X", custom: ["a": "   "]) == "X")
    }

    // MARK: web snapshot

    private func row(_ name: String) -> OverviewRow {
        OverviewRow(id: "SECRET-DEVICE-ID", name: name, status: "Live", health: .warning, isLive: true, fps: 58, battery: 18,
                    isRecording: false, elapsed: 0, issues: [.lowBattery(18)], outputs: [.init(name: "SRT", state: .on)])
    }

    @Test func statusJSONHasNamesAndStateButNoDeviceIds() throws {
        let data = EventStatusJSON.data(rows: [row("Runner <b>3</b>")], now: Date(timeIntervalSince1970: 0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SECRET-DEVICE-ID"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let f = try #require((obj["feeds"] as? [[String: Any]])?.first)
        #expect(f["name"] as? String == "Runner <b>3</b>", "names are data; the page puts them in with textContent")
        #expect(f["health"] as? String == "warning")
        #expect(f["fps"] as? Int == 58 && f["battery"] as? Int == 18)
        #expect(f["issues"] as? [String] == ["low-battery"])
        #expect((f["outputs"] as? [[String: String]])?.first?["state"] == "on")
        #expect(EventStatusJSON.data(rows: []).count > 5)
    }

    @Test func statusPageUsesTextContentNeverMarkup() {
        let html = WebStatusPage.html(token: "tok")
        #expect(html.contains("textContent"))
        #expect(!html.contains("innerHTML"))
        #expect(html.contains("/status.json?t=tok"))
        #expect(!WebStatusPage.html(token: "").contains("?t="))
    }

    @Test func statusRoutesNeedTheTokenLikeEverythingElse() {
        func route(_ path: String, _ q: [String: String]) -> WebRoute {
            WebRequest.route(WebRequest(method: "GET", path: path, query: q), token: "tok")
        }
        #expect(route("/status", ["t": "tok"]) == .statusPage)
        #expect(route("/status.json", ["t": "tok"]) == .statusJSON)
        #expect(route("/status.json", [:]) == .unauthorized)
        #expect(route("/status.json", ["t": "nope"]) == .unauthorized)
        #expect(WebRequest.route(WebRequest(method: "POST", path: "/status.json", query: ["t": "tok"]), token: "tok") == .methodNotAllowed)
    }

    @Test func worstHealthAcrossRows() {
        #expect(OverviewLogic.worst([]) == nil)
        var a = row("a"); a.health = .good
        var b = row("b"); b.health = .bad
        #expect(OverviewLogic.worst([a, b]) == .bad)
        #expect(OverviewLogic.worst([a]) == .good)
    }
}
