import Foundation
import Testing
@testable import GogglesView

struct AutoMarkerPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func labelsAreStable() {
        #expect(AutoMarkerPolicy.label(for: .signalLost) == "Signal lost")
        #expect(AutoMarkerPolicy.label(for: .signalRestored) == "Signal restored")
        #expect(AutoMarkerPolicy.label(for: .replaySaved) == "Replay saved")
        #expect(AutoMarkerPolicy.label(for: .screenshotTaken) == "Screenshot taken")
        #expect(AutoMarkerPolicy.label(for: .raceMode(on: true)) == "Race mode on")
        #expect(AutoMarkerPolicy.label(for: .raceMode(on: false)) == "Race mode off")
        #expect(AutoMarkerPolicy.label(for: .batteryLow(percent: 14)) == "Goggles battery low (14%)")
    }

    @Test func lossAndRestoreBecomeMarkers() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .signalLost, at: t0) == "Signal lost")
        #expect(p.marker(for: .signalRestored, at: t0.addingTimeInterval(8)) == "Signal restored")
    }

    @Test func firstLiveIsNotARestore() {
        // The hooks announce the first live picture as "live"; with no loss marked it must stay silent.
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .signalRestored, at: t0) == nil)
        #expect(p.marker(for: .signalLost, at: t0.addingTimeInterval(10)) != nil)
        #expect(p.marker(for: .signalRestored, at: t0.addingTimeInterval(20)) != nil)
        #expect(p.marker(for: .signalRestored, at: t0.addingTimeInterval(40)) == nil, "a second restore without a loss")
    }

    @Test func sameLabelWithinTwoSecondsIsDropped() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .screenshotTaken, at: t0) != nil)
        #expect(p.marker(for: .screenshotTaken, at: t0.addingTimeInterval(1.9)) == nil)
        #expect(p.marker(for: .screenshotTaken, at: t0.addingTimeInterval(2.0)) != nil)
    }

    @Test func differentLabelsAreNotDeduplicated() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .screenshotTaken, at: t0) != nil)
        #expect(p.marker(for: .replaySaved, at: t0.addingTimeInterval(0.1)) != nil)
        #expect(p.marker(for: .raceMode(on: true), at: t0.addingTimeInterval(0.2)) != nil)
        // On and off are different labels: a quick toggle keeps both.
        #expect(p.marker(for: .raceMode(on: false), at: t0.addingTimeInterval(0.3)) != nil)
    }

    @Test func dedupeWindowIsMeasuredFromTheLastKeptMarker() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .replaySaved, at: t0) != nil)
        #expect(p.marker(for: .replaySaved, at: t0.addingTimeInterval(1.5)) == nil)
        // 1.5 s was dropped, so it does not extend the window: 2.1 s after the kept one is fine.
        #expect(p.marker(for: .replaySaved, at: t0.addingTimeInterval(2.1)) != nil)
    }

    @Test func batteryMarkerOncePerRecording() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .batteryLow(percent: 14), at: t0) == "Goggles battery low (14%)")
        #expect(p.marker(for: .batteryLow(percent: 13), at: t0.addingTimeInterval(600)) == nil)
        p.recordingStarted()
        #expect(p.marker(for: .batteryLow(percent: 12), at: t0.addingTimeInterval(900)) == "Goggles battery low (12%)")
    }

    @Test func recordingStartForgetsDedupeMemory() {
        var p = AutoMarkerPolicy()
        #expect(p.marker(for: .screenshotTaken, at: t0) != nil)
        p.recordingStarted()
        #expect(p.marker(for: .screenshotTaken, at: t0.addingTimeInterval(0.5)) != nil)
    }

    @Test func switchesTurnEventsOff() {
        var p = AutoMarkerPolicy(config: .init(enabled: false))
        #expect(p.marker(for: .signalLost, at: t0) == nil)
        p.config = .init(enabled: true, signal: false, battery: false, captures: false, race: false)
        for e: AutoMarkerPolicy.Event in [.signalLost, .batteryLow(percent: 5), .replaySaved, .screenshotTaken, .raceMode(on: true)] {
            #expect(p.marker(for: e, at: t0) == nil)
        }
        p.config = .init(enabled: true, signal: false, battery: true, captures: false, race: false)
        #expect(p.marker(for: .batteryLow(percent: 5), at: t0) != nil)
    }

    @Test func prefsDefaultToOn() {
        let d = UserDefaults(suiteName: "AutoMarkerTests.\(UUID().uuidString)")!
        #expect(AutoMarkerPrefs.config(d) == AutoMarkerPolicy.Config())
        d.set(false, forKey: AutoMarkerPrefs.enabledKey)
        d.set(false, forKey: AutoMarkerPrefs.raceKey)
        let c = AutoMarkerPrefs.config(d)
        #expect(!c.enabled && !c.race && c.signal && c.battery && c.captures)
    }
}

struct TrimMarkerTests {
    @Test func keepsMarkersInRangeShiftedToTheNewStart() {
        let ms = [ClipMarker(t: 1, label: "before"), ClipMarker(t: 10, label: "in", auto: true),
                  ClipMarker(t: 12.3456, label: "in2"), ClipMarker(t: 20, label: "edge"), ClipMarker(t: 25, label: "after")]
        let out = ClipLibrary.trimmedMarkers(ms, start: 8, end: 20)
        #expect(out.map(\.label) == ["in", "in2", "edge"])
        #expect(out.map(\.t) == [2, 4.346, 12])
        #expect(out.map(\.isAuto) == [true, false, false])
    }

    @Test func emptyWhenNothingFalls() {
        #expect(ClipLibrary.trimmedMarkers([ClipMarker(t: 1, label: "x")], start: 5, end: 9).isEmpty)
    }

    @Test func autoFlagSurvivesTheSidecarAndOldFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trimm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("a.mov")
        #expect(ClipLibrary.writeMarkers([ClipMarker(t: 1, label: "Signal lost", auto: true), ClipMarker(t: 2, label: "Mine")], for: clip))
        let loaded = ClipLibrary.decodeMarkers(try Data(contentsOf: ClipLibrary.sidecarURL(for: clip)))
        #expect(loaded.map(\.isAuto) == [true, false])
        #expect(!ClipLibrary.writeMarkers([], for: dir.appendingPathComponent("none.mov")))
        // A sidecar written before the flag existed.
        let old = Data(#"[{"t":3.5,"label":"Old"}]"#.utf8)
        #expect(ClipLibrary.decodeMarkers(old) == [ClipMarker(t: 3.5, label: "Old")])
        // Manual markers do not gain an "auto" key.
        let manual = try #require(RecordingMarkers.encode([RecordingMarker(t: 1, label: "m")]))
        #expect(!String(decoding: manual, as: UTF8.self).contains("auto"))
    }
}

#if canImport(AppKit)
@Suite(.serialized)
struct AutoMarkerControllerTests {
    private final class Sink { var labels: [String] = [] }

    private func make(recording: Bool, clock: @escaping () -> Date, center: NotificationCenter, deviceId: String = "dev1",
                      session: AnyObject, sink: Sink) -> AutoMarkerController {
        AutoMarkerController(deviceId: deviceId, session: session, isRecording: { recording },
                             addMarker: { sink.labels.append($0) }, now: clock, center: center, config: { .init() })
    }

    /// Notifications from a background thread are handled on main: wait until `count` markers arrived (or 3 s).
    private func settle(_ sink: Sink, count: Int = 0) async {
        for _ in 0..<60 where sink.labels.count < count { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func hookEventsAndCapturesBecomeMarkersForTheirOwnWindowOnly() async {
        let center = NotificationCenter()
        let session = NSObject(), other = NSObject()
        let sink = Sink()
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        let c = make(recording: true, clock: { t }, center: center, session: session, sink: sink)
        defer { _ = c }

        center.post(name: .gogglesRecordingStarted, object: session)
        center.post(name: .gogglesHookEventFired, object: nil, userInfo: ["event": AppEvent.streamLost, "deviceId": "dev1"])
        center.post(name: .gogglesHookEventFired, object: nil, userInfo: ["event": AppEvent.streamLost, "deviceId": "dev2"])
        t.addTimeInterval(5)
        center.post(name: .gogglesHookEventFired, object: nil, userInfo: ["event": AppEvent.streamLive, "deviceId": "dev1"])
        center.post(name: .gogglesHookEventFired, object: nil,
                    userInfo: ["event": AppEvent.batteryLow, "deviceId": "dev1", "percent": 14])
        center.post(name: .gogglesScreenshotSaved, object: session)
        center.post(name: .gogglesScreenshotSaved, object: other)
        center.post(name: .gogglesReplaySaved, object: session)
        center.post(name: .gogglesRaceModeChanged, object: nil, userInfo: ["on": true])
        await settle(sink, count: 6)
        #expect(sink.labels == ["Signal lost", "Signal restored", "Goggles battery low (14%)",
                                "Screenshot taken", "Replay saved", "Race mode on"])
    }

    @Test func nothingIsAddedWhenNotRecording() async {
        let center = NotificationCenter()
        let session = NSObject()
        let sink = Sink()
        let c = make(recording: false, clock: Date.init, center: center, session: session, sink: sink)
        defer { _ = c }
        center.post(name: .gogglesHookEventFired, object: nil, userInfo: ["event": AppEvent.streamLost, "deviceId": "dev1"])
        center.post(name: .gogglesScreenshotSaved, object: session)
        await settle(sink)
        #expect(sink.labels.isEmpty)
    }
}
#endif
