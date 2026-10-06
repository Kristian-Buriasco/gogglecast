import Foundation

/// Exponential reconnect delay shared by the network outputs: 1, 2, 4, 8 s, then capped at 15 s.
enum ReconnectBackoff {
    static let cap: TimeInterval = 15

    /// `attempt` is zero-based (0 = first retry after a failure).
    static func delay(attempt: Int) -> TimeInterval {
        let a = min(max(attempt, 0), 10)
        return min(cap, TimeInterval(1 << a))
    }
}

/// Tracks which outputs (RTMP, SRT, NDI, web viewer, replay saves, ...) are currently active, so
/// the updater can refuse to restart the app while anything is being recorded or sent.
/// Main-thread only; outputs are held weakly.
final class OutputActivityBoard {
    static let shared = OutputActivityBoard()

    private struct Entry { weak var owner: AnyObject?; let isActive: () -> Bool }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var busyTokens = 0

    /// Register `owner`; `isActive` is evaluated lazily and must not retain `owner` strongly.
    func register(_ owner: AnyObject, isActive: @escaping () -> Bool) {
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, isActive: isActive)
    }

    func unregister(_ owner: AnyObject) { entries[ObjectIdentifier(owner)] = nil }

    /// Mark a short-lived job (a replay save) as in progress. Pair with `endBusy()`.
    func beginBusy() { busyTokens += 1 }
    func endBusy() { busyTokens = max(0, busyTokens - 1) }

    var anyActive: Bool {
        entries = entries.filter { $0.value.owner != nil }
        return busyTokens > 0 || entries.values.contains { $0.isActive() }
    }
}
