import Foundation
#if canImport(AppKit)
import AppKit
import SwiftUI
import Combine
import UserNotifications
#endif

// Signal-lost alert for spotters and pilots. Pure decision logic
// (`SignalAlertPolicy`) with an injected clock, user prefs (`SignalAlertPrefs`)
// and a thin AppKit controller that turns policy outputs into a user
// notification and a repeating sound. The existing streamLost/streamLive event
// hook is untouched: this file never posts to `EventBus`.

/// User preferences, backed by UserDefaults.
enum SignalAlertPrefs {
    static let enabledKey = "signalAlertEnabled"
    static let thresholdKey = "signalAlertThresholdSeconds"
    static let soundEnabledKey = "signalAlertSoundEnabled"
    static let soundNameKey = "signalAlertSoundName"

    static let defaultEnabled = true
    static let defaultThreshold = 3
    static let thresholdRange = 1...15
    static let defaultSoundEnabled = true
    static let defaultSoundName = "Sosumi"
    static let repeatInterval: TimeInterval = 5
    static let restoredSoundName = "Glass"
    /// Standard macOS sounds offered in Settings.
    static let soundChoices = ["Sosumi", "Basso", "Funk", "Hero", "Ping", "Submarine"]

    static func clampThreshold(_ v: Int) -> Int {
        min(max(v, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    static func enabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
    static func threshold(_ d: UserDefaults = .standard) -> Int {
        clampThreshold(d.object(forKey: thresholdKey) as? Int ?? defaultThreshold)
    }
    static func soundEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: soundEnabledKey) as? Bool ?? defaultSoundEnabled
    }
    static func soundName(_ d: UserDefaults = .standard) -> String {
        let n = d.string(forKey: soundNameKey) ?? defaultSoundName
        return soundChoices.contains(n) ? n : defaultSoundName
    }
    static func policyConfig(_ d: UserDefaults = .standard) -> SignalAlertPolicy.Config {
        .init(threshold: TimeInterval(threshold(d)), repeatInterval: repeatInterval)
    }
}

/// Pure state machine. Feed it frame arrivals and clock ticks; it says when to
/// alert. It never reads a clock itself.
struct SignalAlertPolicy {
    struct Config: Equatable {
        var threshold: TimeInterval = TimeInterval(SignalAlertPrefs.defaultThreshold)
        var repeatInterval: TimeInterval = SignalAlertPrefs.repeatInterval
    }

    enum Output: Equatable { case lost, restored, repeatReminder }

    var config: Config
    /// Time of the last picture; nil until the first one (no alert before it).
    private(set) var lastFrameAt: Date?
    private(set) var isLost = false
    private var lastAlertAt: Date?
    private var acknowledged = false
    private var disconnected = false

    init(config: Config = Config()) { self.config = config }

    /// A picture arrived. Returns `.restored` if an alert was active.
    mutating func frameArrived(at time: Date) -> Output? {
        disconnected = false
        lastFrameAt = time
        guard isLost else { return nil }
        isLost = false
        acknowledged = false
        lastAlertAt = nil
        return .restored
    }

    /// Periodic clock evaluation.
    mutating func tick(now: Date) -> Output? {
        guard !disconnected, let last = lastFrameAt else { return nil }
        if !isLost {
            guard now.timeIntervalSince(last) >= config.threshold else { return nil }
            isLost = true
            lastAlertAt = now
            return .lost
        }
        guard !acknowledged, let lastAlert = lastAlertAt,
              now.timeIntervalSince(lastAlert) >= config.repeatInterval else { return nil }
        lastAlertAt = now
        return .repeatReminder
    }

    /// The user closed the window or quit: forget everything, stay silent until
    /// a new picture arrives.
    mutating func userDisconnected() {
        disconnected = true
        isLost = false
        lastFrameAt = nil
        lastAlertAt = nil
        acknowledged = false
    }

    /// The user saw the alert (e.g. brought the app forward): stop reminders but
    /// keep the lost state so `.restored` still fires.
    mutating func acknowledge() { acknowledged = true }
}

#if canImport(AppKit)
/// Adapts one session's `uiState` to the policy plus notification and sound.
final class SignalAlertController {
    private var policy = SignalAlertPolicy(config: SignalAlertPrefs.policyConfig())
    private let now: () -> Date
    private let deviceLabel: () -> String
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastKind: GogglesUIStateKind?
    private var sound: NSSound?

    /// The watchdog marks a stream stalled after this much silence, so the
    /// last picture was about this long before the state left `.live`.
    static let watchdogSilence: TimeInterval = 2

    init(coordinator: GogglesConnectionCoordinator,
         deviceLabel: @escaping () -> String = { "Goggles" },
         now: @escaping () -> Date = Date.init) {
        self.now = now
        self.deviceLabel = deviceLabel
        coordinator.$uiState.sink { [weak self] s in self?.stateChanged(s.kind) }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.policy.acknowledge(); self?.stopSound() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.userDisconnected() }
            .store(in: &bag)
    }

    deinit { timer?.invalidate() }

    /// Window closed or session torn down by the user.
    func userDisconnected() {
        policy.userDisconnected()
        lastKind = nil
        timer?.invalidate(); timer = nil
        stopSound()
        bag.removeAll()
    }

    private func stateChanged(_ kind: GogglesUIStateKind) {
        defer { lastKind = kind }
        guard SignalAlertPrefs.enabled() else { return }
        policy.config = SignalAlertPrefs.policyConfig()
        let t = now()
        if kind == .live {
            if lastKind != .live { handle(policy.frameArrived(at: t)) }
        } else if lastKind == .live {
            handle(policy.frameArrived(at: t.addingTimeInterval(-Self.watchdogSilence)))
            startTimer()
            evaluate()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func evaluate() {
        guard SignalAlertPrefs.enabled() else { stopSound(); return }
        policy.config = SignalAlertPrefs.policyConfig()
        handle(policy.tick(now: now()))
        // Back to live and nothing pending: no need to keep polling.
        if lastKind == .live, !policy.isLost {
            timer?.invalidate(); timer = nil
        }
    }

    private func handle(_ output: SignalAlertPolicy.Output?) {
        guard let output else { return }
        switch output {
        case .lost:
            SignalAlertNotifier.post(title: "Signal lost", body: "\(deviceLabel()) stopped sending video.", id: "lost")
            playAlertSound()
        case .repeatReminder:
            playAlertSound()
        case .restored:
            stopSound()
            SignalAlertNotifier.post(title: "Signal restored", body: "\(deviceLabel()) is sending video again.", id: "restored")
            if SignalAlertPrefs.soundEnabled() { SignalAlertSound.play(SignalAlertPrefs.restoredSoundName) }
        }
    }

    private func playAlertSound() {
        guard SignalAlertPrefs.soundEnabled() else { return }
        sound = SignalAlertSound.play(SignalAlertPrefs.soundName())
    }

    private func stopSound() { sound?.stop(); sound = nil }
}

enum SignalAlertSound {
    @discardableResult
    static func play(_ name: String) -> NSSound? {
        guard let s = NSSound(named: NSSound.Name(name)) else { return nil }
        s.play()
        return s
    }
}

/// UserNotifications wrapper. Authorization is requested lazily on the first
/// alert; unbundled runs (swift run, tests) skip it because the framework
/// crashes without an app bundle.
enum SignalAlertNotifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func post(title: String, body: String, id: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { deliver(center, title: title, body: body, id: id) }
                }
            case .denied:
                break
            default:
                deliver(center, title: title, body: body, id: id)
            }
        }
    }

    private static func deliver(_ center: UNUserNotificationCenter, title: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.interruptionLevel = .timeSensitive
        center.removeDeliveredNotifications(withIdentifiers: ["signal-lost", "signal-restored"])
        center.add(UNNotificationRequest(identifier: "signal-\(id)", content: c, trigger: nil))
    }
}

/// Settings card.
struct SignalAlertSettingsSection: View {
    @AppStorage(SignalAlertPrefs.enabledKey) private var enabled = SignalAlertPrefs.defaultEnabled
    @AppStorage(SignalAlertPrefs.thresholdKey) private var threshold = SignalAlertPrefs.defaultThreshold
    @AppStorage(SignalAlertPrefs.soundEnabledKey) private var soundOn = SignalAlertPrefs.defaultSoundEnabled
    @AppStorage(SignalAlertPrefs.soundNameKey) private var soundName = SignalAlertPrefs.defaultSoundName

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signal-lost alert").font(.headline)
            Toggle("Alert when the video signal is lost", isOn: $enabled)
            Stepper("After \(threshold) s without video", value: $threshold, in: SignalAlertPrefs.thresholdRange)
                .disabled(!enabled)
            Toggle("Repeat a sound until the signal returns", isOn: $soundOn).disabled(!enabled)
            HStack {
                Picker("Sound", selection: $soundName) {
                    ForEach(SignalAlertPrefs.soundChoices, id: \.self) { Text($0).tag($0) }
                }
                Button("Test") { SignalAlertSound.play(soundName) }
            }
            .disabled(!enabled || !soundOn)
            Text("Notifications need permission in System Settings > Notifications. The sound follows the system volume and stops when you bring GogglesView forward. Nothing is shown when you close the window or quit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
