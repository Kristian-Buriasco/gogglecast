import Foundation
import Testing
@testable import GogglesView

@Suite("Menu bar mini-controls model")
struct MenuBarMiniControlsTests {
    private func snap(live: Bool = true, recording: Bool = false, elapsed: TimeInterval = 0,
                      frozen: Bool = false, streaming: Bool = false, streamAvailable: Bool = true,
                      replay: Bool = true, visible: Bool = true, fps: Int? = 60, battery: Int? = 80) -> MiniControlsSnapshot {
        MiniControlsSnapshot(label: "Goggles 3 (…1234)", statusText: live ? "Live" : "Waiting for video…",
                             isLive: live, fps: fps, batteryPercent: battery, isRecording: recording,
                             recordingElapsed: elapsed, isFrozen: frozen, isNetworkStreaming: streaming,
                             networkStreamAvailable: streamAvailable, replayEnabled: replay, isWindowVisible: visible)
    }

    private func item(_ action: MiniControlAction, _ s: MiniControlsSnapshot) -> MiniControlItem {
        MenuBarMiniControls.items(s).first { $0.action == action }!
    }

    @Test func formatElapsed() {
        #expect(MenuBarMiniControls.formatElapsed(0) == "00:00")
        #expect(MenuBarMiniControls.formatElapsed(187.9) == "03:07")
        #expect(MenuBarMiniControls.formatElapsed(-5) == "00:00")
    }

    @Test func headerAndInfoLine() {
        #expect(MenuBarMiniControls.headerTitle(snap()) == "Goggles 3 (…1234) — Live")
        #expect(MenuBarMiniControls.headerTitle(snap(recording: true, elapsed: 83)) == "Goggles 3 (…1234) — Live · ● REC 01:23")
        #expect(MenuBarMiniControls.infoLine(snap()) == "60 fps · Battery 80% · Not recording")
        #expect(MenuBarMiniControls.infoLine(snap(recording: true, elapsed: 5)) == "60 fps · Battery 80% · Recording 00:05")
        #expect(MenuBarMiniControls.infoLine(snap(live: false, battery: nil)) == "— fps · Not recording")
    }

    @Test func everyActionAppearsOnceInOrder() {
        #expect(MenuBarMiniControls.items(snap()).map(\.action) == MiniControlAction.allCases)
    }

    @Test func recordingItem() {
        let idle = item(.toggleRecording, snap())
        #expect(idle.title == "Start Recording" && idle.isEnabled && !idle.isOn)
        #expect(!item(.toggleRecording, snap(live: false)).isEnabled)
        let rec = item(.toggleRecording, snap(live: false, recording: true))
        #expect(rec.title == "Stop Recording" && rec.isEnabled && rec.isOn)
    }

    @Test func liveOnlyActions() {
        #expect(item(.screenshot, snap()).isEnabled)
        #expect(!item(.screenshot, snap(live: false)).isEnabled)
        #expect(item(.saveReplay, snap()).isEnabled)
        #expect(!item(.saveReplay, snap(live: false)).isEnabled)
        let off = item(.saveReplay, snap(replay: false))
        #expect(!off.isEnabled && off.title == "Save Replay (off in Settings)")
    }

    @Test func freezeMarkerWindowStream() {
        #expect(item(.toggleFreeze, snap()).title == "Freeze Video")
        let frozen = item(.toggleFreeze, snap(live: false, frozen: true))
        #expect(frozen.title == "Resume Video" && frozen.isEnabled && frozen.isOn)
        #expect(!item(.addMarker, snap()).isEnabled)
        #expect(item(.addMarker, snap(recording: true)).isEnabled)
        #expect(item(.showWindow, snap()).title == "Hide Window")
        #expect(item(.showWindow, snap(visible: false)).title == "Show Window")
        #expect(item(.toggleNetworkStream, snap()).title == "Start Network Stream")
        let streaming = item(.toggleNetworkStream, snap(streaming: true))
        #expect(streaming.title == "Stop Network Stream" && streaming.isOn)
        #expect(!item(.toggleNetworkStream, snap(streamAvailable: false)).isEnabled)
    }

    @Test func hotkeyDispatchAndRecordingSummary() {
        #expect(MiniControlAction.toggleRecording.hotkeyAction == .toggleRecording)
        #expect(MiniControlAction.saveReplay.hotkeyAction == .saveReplay)
        #expect(MiniControlAction.screenshot.hotkeyAction == .screenshot)
        #expect(MiniControlAction.toggleFreeze.hotkeyAction == nil)
        #expect(!MenuBarMiniControls.anyRecording([]))
        #expect(!MenuBarMiniControls.anyRecording([snap(), snap()]))
        #expect(MenuBarMiniControls.anyRecording([snap(), snap(recording: true)]))
    }

    @Test func showPrefDefaultsOn() {
        let d = UserDefaults(suiteName: "MenuBarMiniControlsTests-\(UUID())")!
        #expect(MenuBarPrefs.show(defaults: d))
        d.set(false, forKey: MenuBarPrefs.showKey)
        #expect(!MenuBarPrefs.show(defaults: d))
    }
}
