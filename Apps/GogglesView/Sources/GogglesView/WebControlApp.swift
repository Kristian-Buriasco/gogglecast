import Foundation
import AppKit

/// Runs browser actions through the same paths as AppleScript / Shortcuts (`AutomationController`),
/// always on the main thread, so the web server queue never waits for the app.
final class AppControlSink: ControlSink {
    func perform(_ action: ControlAction, feed: Int?, completion: @escaping (ControlResult) -> Void) {
        DispatchQueue.main.async { completion(self.run(action, feed: feed)) }
    }

    private func ok(_ m: String) -> ControlResult { ControlResult(ok: true, message: m) }
    private func no(_ m: String) -> ControlResult { ControlResult(ok: false, message: m) }

    private func run(_ action: ControlAction, feed: Int?) -> ControlResult {
        let d = UserDefaults.standard
        switch action {
        case .outputsShow: d.set(true, forKey: ProgramOutputPrefs.enabledKey); return ok("HDMI program outputs shown")
        case .outputsHide: d.set(false, forKey: ProgramOutputPrefs.enabledKey); return ok("HDMI program outputs hidden")
        case .awayOn, .awayOff:
            if action == .awayOn, !AlertCenter.shared.configured { return no("Set up the ntfy server and topic in Settings first") }
            AlertPrefs.setAway(action == .awayOn)
            return ok(action == .awayOn ? "Away mode on" : "Away mode off")
        case .alertsTest:
            guard AlertCenter.shared.configured else { return no("Remote alerts are not set up") }
            AlertCenter.shared.sendTests()
            return ok("Test alerts sent")
        case .previewOn, .previewOff:
            return no("Preview on this Mac cannot be switched from the browser in this version")
        default: break
        }
        // Per-feed actions: the index must still match the window it was read from.
        let rows = EventStatus.shared.rows, sessions = AutomationController.shared.openSessions
        guard let i = feed, rows.indices.contains(i), sessions.indices.contains(i), sessions[i].deviceId == rows[i].id else {
            return no("No such feed (the list changed, wait a second)")
        }
        let row = rows[i], session = sessions[i]
        func command(_ c: AutomationCommand, _ done: String) -> ControlResult {
            switch AutomationController.shared.perform(AutomationRequest(command: c, device: row.id)) {
            case .done: return ok(done)
            case .disabled: return no("Automation is turned off in Settings")
            case .noTarget: return no("Feed not found")
            case .unavailable(let m): return no(m)
            }
        }
        switch action {
        case .recordStart:
            if row.isRecording { return no("Already recording") }
            guard row.isLive else { return no("Feed is not live") }
            return command(.startRecording, "Recording started")
        case .recordStop:
            guard row.isRecording else { return no("Not recording") }
            return command(.stopRecording, "Recording stopped")
        case .replaySave:
            guard row.isLive else { return no("Feed is not live") }
            return command(.saveReplay, "Replay saved")
        case .markerAdd:
            guard row.isRecording else { return no("A marker needs a recording") }
            return command(.addMarker(label: AutomationURLParser.defaultMarkerLabel), "Marker added")
        case .screenshot:
            guard row.isLive else { return no("Feed is not live") }
            return command(.screenshot, "Screenshot taken")
        case .reconnect:
            session.coordinator.reconnect()
            return ok("Reconnecting")
        default: return no("Unsupported action")
        }
    }

    /// Latest decoded frame of feed `i` for thumbnails. Called on the thumbnail queue; hops to main only to find the session.
    static func frame(_ i: Int) -> CVPixelBuffer? {
        let session = DispatchQueue.main.sync { () -> DecodeSession? in
            let s = AutomationController.shared.openSessions
            return s.indices.contains(i) ? s[i].decodeSession : nil
        }
        return session?.latestDecodedFrame()
    }
}

/// Builds the `/api/state` snapshot once a second (called from `EventStatus.refresh`) and logs signal changes.
final class ControlFeeder {
    static let shared = ControlFeeder()
    private let started = Date()
    private var wasLive: [String: Bool] = [:]

    func publish(rows: [OverviewRow], sessions: [GogglesSession], now: Date) {
        let names = ProgramFeedNaming.names(deviceIds: rows.map(\.id), custom: ProgramOutputPrefs.feedNames())
        for (r, n) in zip(rows, names) {
            if let was = wasLive[r.id], was != r.isLive {
                ControlLog.shared.add(.signal, who: "system", text: (r.isLive ? "Signal back: " : "Signal lost: ") + n, ok: r.isLive, at: now)
            }
            wasLive[r.id] = r.isLive
        }
        for k in Set(wasLive.keys).subtracting(rows.map(\.id)) { wasLive[k] = nil }

        var extra = ProgramOutputController.shared.outputChips
        for s in sessions { extra += SessionControlBoard.shared.alertChips(for: s.decodeSession).filter { $0.name != "SRT" && $0.name != "UDP" && $0.name != "NDI" } }
        let g = ControlState.Globals(away: AlertPrefs.away(), awayConfigured: AlertCenter.shared.configured,
                                     hdmiShown: ProgramOutputPrefs.enabled(), previewAvailable: false,
                                     controlEnabled: ControlPrefs.enabled, uptime: now.timeIntervalSince(started), extraOutputs: extra)
        ControlStateStore.set(ControlState.data(rows: rows, names: names, globals: g, log: ControlLog.shared.recent(50), now: now))
    }
}
