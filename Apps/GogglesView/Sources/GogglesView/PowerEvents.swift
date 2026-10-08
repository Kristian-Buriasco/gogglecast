import Foundation
#if canImport(AppKit)
import AppKit

/// What `PowerEvents` needs from a goggles window. `GogglesSession` is the real one; tests use a stub.
protocol PowerAwareSession: AnyObject {
    /// The Mac is about to sleep: mark any running recording and go quiet for the signal alert.
    func powerWillSleep()
    /// The Mac woke up: the USB link and the helper connection are likely stale.
    func powerDidWake()
}

/// Holds a process activity assertion while something that must not be interrupted is running
/// (a recording or any output), and releases it when idle. This keeps the Mac from idle sleep and
/// the app from App Nap in the middle of a recording.
///
/// Polled by a light timer (the state lives in several places: recorders, streamers, outputs), and
/// the begin/end calls are injectable so the logic is unit-tested without touching the system.
final class PowerActivityKeeper {
    static let reason = "GogglesView is recording or sending video"

    private let isBusy: () -> Bool
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?
    private var timer: Timer?

    init(
        isBusy: @escaping () -> Bool,
        begin: @escaping (String) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: $0)
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.isBusy = isBusy
        self.begin = begin
        self.end = end
    }

    deinit { stop() }

    var isHolding: Bool { token != nil }

    /// Starts polling (every `interval` seconds). Idempotent.
    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        evaluate()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let token { end(token); self.token = nil }
    }

    /// Takes or releases the assertion to match the current busy state.
    func evaluate() {
        let busy = isBusy()
        if busy, token == nil {
            token = begin(Self.reason)
        } else if !busy, let t = token {
            end(t)
            token = nil
        }
    }
}

/// Sleep and wake handling. On sleep every window's recording gets a marker and the signal alert
/// goes quiet (so the stream dropping because the Mac sleeps does not raise an alarm); about a
/// second after wake every session reconnects, since the USB link and helper connection rarely
/// survive sleep.
final class PowerEvents {
    static let shared = PowerEvents()

    static let wakeReconnectDelay: TimeInterval = 1
    static var sleepMarkerLabel: String { L("Mac went to sleep") }

    private var observers: [NSObjectProtocol] = []
    private var keeper: PowerActivityKeeper?
    private let center: NotificationCenter
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var sessions: () -> [PowerAwareSession] = { [] }

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.center = center
        self.schedule = schedule
    }

    deinit { observers.forEach { center.removeObserver($0) } }

    /// Starts observing. `isBusy` drives the activity assertion; pass nil to skip it (tests).
    func install(sessions: @escaping () -> [PowerAwareSession], isBusy: (() -> Bool)? = nil) {
        guard observers.isEmpty else { return }
        self.sessions = sessions
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        })
        if let isBusy {
            let k = PowerActivityKeeper(isBusy: isBusy)
            k.start()
            keeper = k
        }
    }

    func willSleep() {
        sessions().forEach { $0.powerWillSleep() }
    }

    func didWake() {
        // Sessions are looked up again after the delay: one may have been closed meanwhile.
        schedule(Self.wakeReconnectDelay) { [weak self] in
            self?.sessions().forEach { $0.powerDidWake() }
        }
    }
}

extension GogglesSession: PowerAwareSession {}
#endif
