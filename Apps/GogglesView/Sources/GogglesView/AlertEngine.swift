import Foundation

// Remote alerts: pure decision logic. Conditions in (what is wrong right now), messages out (what to
// send to ntfy). No clock, no network, no UserDefaults reads inside the engine: tests inject everything.
// Nothing here runs unless the user turned Away mode on (see AlertPrefs).

enum AlertKind: String, CaseIterable, Identifiable {
    case signalLost, pictureFrozen, pictureBlack, batteryLow, batteryCritical, outputFailed, outputStalled, helperNotResponding
    var id: String { rawValue }

    /// Short English-keyed title, also the settings row label.
    var title: String {
        switch self {
        case .signalLost: return L("Signal lost")
        case .pictureFrozen: return L("Picture frozen")
        case .pictureBlack: return L("Black picture")
        case .batteryLow: return L("Battery low")
        case .batteryCritical: return L("Battery critical")
        case .outputFailed: return L("Output failed")
        case .outputStalled: return L("Output waiting for connection")
        case .helperNotResponding: return L("Helper not responding")
        }
    }

    var recoveryText: String {
        switch self {
        case .signalLost: return L("Signal back")
        case .pictureFrozen: return L("Picture moving again")
        case .pictureBlack: return L("Picture no longer black")
        case .batteryLow, .batteryCritical: return L("Battery recovered")
        case .outputFailed: return L("Output working again")
        case .outputStalled: return L("Output connected")
        case .helperNotResponding: return L("Helper responding again")
        }
    }

    /// Defaults: urgent (5) for signal lost and output failed, high (4) for critical battery, frozen
    /// picture and a dead helper, default (3) for the rest.
    var defaultPriority: Int {
        switch self {
        case .signalLost, .outputFailed: return 5
        case .batteryCritical, .pictureFrozen, .helperNotResponding: return 4
        case .pictureBlack, .batteryLow, .outputStalled: return 3
        }
    }

    /// Seconds a condition must last before the first alert (on top of the 3 s stream debounce).
    var defaultDelay: Int {
        switch self {
        case .batteryLow, .batteryCritical: return 0
        case .signalLost, .outputFailed: return 10
        case .helperNotResponding: return 15
        case .pictureFrozen, .pictureBlack: return 20
        case .outputStalled: return 30
        }
    }

    var tag: String {
        switch self {
        case .signalLost, .outputFailed, .helperNotResponding: return "rotating_light"
        default: return "warning"
        }
    }
}

/// One thing that can be wrong. `feedID` is internal (device id, "helper", output id): it never reaches a
/// message. `detail` is the output name (SRT, RTMP, ...) or empty.
struct AlertKey: Hashable {
    let kind: AlertKind
    let feedID: String
    let detail: String
}

struct AlertCondition: Equatable {
    let key: AlertKey
    /// Crew name of the feed (ProgramFeedNaming), never a serial number or device id.
    let name: String
}

struct AlertMessage: Equatable {
    let title: String
    let body: String
    /// ntfy priority 1...5.
    let priority: Int
    let tags: String
    let isRecovery: Bool
}

struct AlertConfig: Equatable {
    struct Setting: Equatable { var enabled = true; var delay = 0; var priority = 3 }
    var away = false
    /// Minutes between reminders while still failing; 0 = no reminders.
    var repeatMinutes = 2
    var maxRepeats = 10
    /// A condition must stay clear this long before the recovery message (stops flap spam).
    var recoveryHold: TimeInterval = 5
    var settings: [AlertKind: Setting] = Dictionary(uniqueKeysWithValues: AlertKind.allCases.map {
        ($0, Setting(enabled: true, delay: $0.defaultDelay, priority: $0.defaultPriority))
    })
    func setting(_ k: AlertKind) -> Setting { settings[k] ?? Setting(enabled: true, delay: k.defaultDelay, priority: k.defaultPriority) }
}

struct AlertEngine {
    private struct Track {
        var name: String
        let firstSeen: Date
        var fired = false
        var lastSent = Date.distantPast
        var repeats = 0
        var clearedSince: Date?
    }
    private var tracks: [AlertKey: Track] = [:]

    var trackedCount: Int { tracks.count }

    /// Drop everything silently (feed closed by the user, away mode off).
    mutating func reset() { tracks = [:] }
    mutating func forget(feedID: String) { tracks = tracks.filter { $0.key.feedID != feedID } }

    /// `active` is the full list of conditions that hold right now. Call about once a second.
    mutating func update(_ active: [AlertCondition], config: AlertConfig, now: Date) -> [AlertMessage] {
        guard config.away else { reset(); return [] }
        let enabled = active.filter { config.setting($0.key.kind).enabled }
        let current = Dictionary(enabled.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [AlertMessage] = []

        // Critical battery replaces low battery: no second message, no "recovered" in between.
        func superseded(_ k: AlertKey) -> Bool {
            k.kind == .batteryLow && current[AlertKey(kind: .batteryCritical, feedID: k.feedID, detail: k.detail)] != nil
        }

        for (key, name) in current.sorted(by: { $0.key.feedID + $0.key.kind.rawValue + $0.key.detail < $1.key.feedID + $1.key.kind.rawValue + $1.key.detail }) {
            var t = tracks[key] ?? Track(name: name, firstSeen: now)
            t.name = name
            t.clearedSince = nil
            let s = config.setting(key.kind)
            if !superseded(key) {
                if !t.fired {
                    if now.timeIntervalSince(t.firstSeen) >= TimeInterval(s.delay) {
                        t.fired = true; t.lastSent = now
                        out.append(Self.message(key, name, s.priority, repeatNo: 0))
                    }
                } else if config.repeatMinutes > 0, t.repeats < config.maxRepeats,
                          now.timeIntervalSince(t.lastSent) >= TimeInterval(config.repeatMinutes * 60) {
                    t.repeats += 1; t.lastSent = now
                    out.append(Self.message(key, name, s.priority, repeatNo: t.repeats))
                }
            }
            tracks[key] = t
        }

        for (key, var t) in tracks where current[key] == nil {
            guard t.fired else { tracks[key] = nil; continue }   // never alerted: nothing to recover
            let since = t.clearedSince ?? now
            t.clearedSince = since
            if now.timeIntervalSince(since) >= config.recoveryHold {
                tracks[key] = nil
                if !superseded(key) { out.append(Self.recovery(key, t.name)) }
            } else {
                tracks[key] = t
            }
        }
        return out
    }

    private static func label(_ key: AlertKey, _ name: String) -> String {
        key.detail.isEmpty ? name : "\(name) / \(key.detail)"
    }

    static func message(_ key: AlertKey, _ name: String, _ priority: Int, repeatNo: Int) -> AlertMessage {
        var body = "\(label(key, name)): \(key.kind.title)"
        if repeatNo > 0 { body += " (" + L("still failing, reminder %lld", repeatNo) + ")" }
        return AlertMessage(title: "GogglesView: " + key.kind.title, body: body,
                            priority: min(max(priority, 1), 5), tags: key.kind.tag, isRecovery: false)
    }

    static func recovery(_ key: AlertKey, _ name: String) -> AlertMessage {
        AlertMessage(title: "GogglesView: " + key.kind.recoveryText, body: "\(label(key, name)): \(key.kind.recoveryText)",
                     priority: 3, tags: "white_check_mark", isRecovery: true)
    }
}

// MARK: Inputs

/// What the app knows about one feed, copied out of the operator overview row.
struct AlertFeed {
    let id: String
    let name: String
    let isLive: Bool
    let issues: [FeedIssue]
    let outputs: [OutputChip]
}

/// Turns app state into conditions. Signal lost reuses `StreamEventDebouncer`: a feed that was never
/// announced live never alerts, and a flapping signal does not flip the condition.
struct AlertInputs {
    private var debouncers: [String: StreamEventDebouncer] = [:]
    private var lost = Set<String>()

    /// Feeds that disappeared (window closed by the user) so the engine can forget them.
    mutating func conditions(feeds: [AlertFeed], helperDown: Bool, missingPrograms: [String], now: Date) -> (conditions: [AlertCondition], gone: [String]) {
        let ids = Set(feeds.map(\.id))
        let gone = Set(debouncers.keys).subtracting(ids)
        for id in gone { debouncers[id] = nil; lost.remove(id) }
        var out: [AlertCondition] = []
        for f in feeds {
            var d = debouncers[f.id] ?? StreamEventDebouncer()
            d.observe(f.isLive ? .live : .stalled, at: now)
            if let e = d.tick(at: now) { if e == .streamLost { lost.insert(f.id) } else { lost.remove(f.id) } }
            debouncers[f.id] = d
            func add(_ k: AlertKind, _ detail: String = "") { out.append(AlertCondition(key: AlertKey(kind: k, feedID: f.id, detail: detail), name: f.name)) }
            if lost.contains(f.id) { add(.signalLost) }
            for i in f.issues {
                switch i {
                case .lowBattery: add(.batteryLow)
                case .criticalBattery: add(.batteryCritical)
                case .frozenPicture: add(.pictureFrozen)
                case .blackPicture: add(.pictureBlack)
                }
            }
            for c in f.outputs {
                if c.state == .error { add(.outputFailed, c.name) } else if c.state == .waiting { add(.outputStalled, c.name) }
            }
        }
        for n in missingPrograms {
            out.append(AlertCondition(key: AlertKey(kind: .outputFailed, feedID: "program:" + n, detail: L("display")), name: n))
        }
        if helperDown {
            out.append(AlertCondition(key: AlertKey(kind: .helperNotResponding, feedID: "helper", detail: ""), name: "GogglesView"))
        }
        return (out, Array(gone))
    }
}

// MARK: Preferences

/// Plain defaults only: the server, topic and switches are not secrets. The token is in SecretStore.
enum AlertPrefs {
    static let serverKey = "remoteAlertsServer"
    static let topicKey = "remoteAlertsTopic"
    static let awayKey = "remoteAlertsAway"
    static let repeatKey = "remoteAlertsRepeatMinutes"
    static let heartbeatKey = "remoteAlertsHeartbeatURL"
    static let tokenKey = "remoteAlertsToken"
    static let repeatRange = 0...60

    static func enabledKey(_ k: AlertKind) -> String { "remoteAlerts.\(k.rawValue).enabled" }
    static func delayKey(_ k: AlertKind) -> String { "remoteAlerts.\(k.rawValue).delay" }
    static func priorityKey(_ k: AlertKind) -> String { "remoteAlerts.\(k.rawValue).priority" }

    static func away(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: awayKey) }
    static func setAway(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: awayKey) }

    static func config(_ d: UserDefaults = .standard) -> AlertConfig {
        var c = AlertConfig()
        c.away = away(d)
        c.repeatMinutes = min(max(d.object(forKey: repeatKey) as? Int ?? 2, repeatRange.lowerBound), repeatRange.upperBound)
        for k in AlertKind.allCases {
            c.settings[k] = .init(enabled: d.object(forKey: enabledKey(k)) as? Bool ?? true,
                                  delay: min(max(d.object(forKey: delayKey(k)) as? Int ?? k.defaultDelay, 0), 600),
                                  priority: min(max(d.object(forKey: priorityKey(k)) as? Int ?? k.defaultPriority, 1), 5))
        }
        return c
    }
}
