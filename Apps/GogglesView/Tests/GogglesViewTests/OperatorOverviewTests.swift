import Foundation
import Testing
@testable import GogglesView

@Suite struct OperatorOverviewTests {
    private func row(_ id: String, live: Bool, rec: Bool) -> OverviewRow {
        OverviewRow(id: id, name: id, status: "", health: live ? .good : .bad, isLive: live, fps: nil, battery: nil, isRecording: rec, elapsed: 0)
    }

    @Test func recordAllStartsOnlyLiveWindowsThatAreNotRecording() {
        let rows = [row("a", live: true, rec: false), row("b", live: true, rec: true),
                    row("c", live: false, rec: false), row("d", live: true, rec: false)]
        #expect(OverviewLogic.toStartRecording(rows) == ["a", "d"])
    }

    @Test func stopAllStopsEveryRecordingEvenWithoutSignal() {
        let rows = [row("a", live: true, rec: true), row("b", live: false, rec: true), row("c", live: true, rec: false)]
        #expect(OverviewLogic.toStopRecording(rows) == ["a", "b"])
    }

    @Test func healthColorsFollowTheConnectionState() {
        #expect(OverviewLogic.health(for: .live) == .good)
        for k in [GogglesUIStateKind.stalled, .waitingForKeyframe, .handshaking, .resolving, .claiming] {
            #expect(OverviewLogic.health(for: k) == .warning)
        }
        for k in [GogglesUIStateKind.noDevice, .noHelper, .claimFailed] { #expect(OverviewLogic.health(for: k) == .bad) }
        #expect(Set(GogglesUIStateKind.allCases.map { OverviewLogic.health(for: $0) }).count == 3)
    }

    @Test func diskLevelScalesWithTheNumberOfRecordings() {
        let gb: Int64 = 1_000_000_000
        #expect(OverviewLogic.diskLevel(freeBytes: 200 * gb, recordings: 4) == .ok)
        #expect(OverviewLogic.diskLevel(freeBytes: 60 * gb, recordings: 4) == .low)
        #expect(OverviewLogic.diskLevel(freeBytes: 30 * gb, recordings: 4) == .critical)
        #expect(OverviewLogic.diskLevel(freeBytes: 20 * gb, recordings: 1) == .low)
        #expect(OverviewLogic.diskLevel(freeBytes: nil, recordings: 2) == .unknown)
        #expect(OverviewLogic.diskLevel(freeBytes: -5, recordings: 0) == .critical)
    }

    @Test func hoursLeftHandlesNoRecordings() {
        #expect(OverviewLogic.hoursLeft(freeBytes: 18_000_000_000, recordings: 0) == 2)
        #expect(OverviewLogic.hoursLeft(freeBytes: 18_000_000_000, recordings: 2) == 1)
    }

    @Test func elapsedIsFormattedAsClockTime() {
        #expect(OverviewLogic.formatElapsed(0) == "0:00:00")
        #expect(OverviewLogic.formatElapsed(3725.9) == "1:02:05")
        #expect(OverviewLogic.formatElapsed(86_400 + 61) == "24:01:01")
    }

    @Test func eventPresetSetsAutoRecordSplitAndAlert() {
        let d = UserDefaults(suiteName: "event-\(UUID().uuidString)")!
        SettingsPreset.event.apply(to: d)
        #expect(d.bool(forKey: RecordingPrefs.autoStartKey))
        #expect(d.integer(forKey: RecordingExtras.splitMinutesKey) == 30)
        #expect(d.bool(forKey: SignalAlertPrefs.enabledKey))
        #expect(d.object(forKey: ReplayPrefs.enabledKey) as? Bool == false)
        SettingsPreset.minimal.apply(to: d)
        #expect(d.object(forKey: RecordingExtras.splitMinutesKey) == nil, "the next preset clears what event set")
    }

    @Test func srtAutoStartIsInTheSettingsBackup() {
        #expect(SettingsBackup.allowedKeys.contains(SRTPrefs.autoStartKey) && SettingsBackup.allowedKeys.contains(ReencodePrefs.halfRateKey) && SettingsBackup.allowedKeys.contains(FeedPortPrefs.perFeedKey))
    }
}
