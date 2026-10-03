import Foundation

/// What `SessionRegistry` needs from a session. `GogglesSession` is the real
/// one; tests use a plain stub (no windows/XPC).
protocol RegistrableSession: AnyObject {
    var deviceId: String { get }
    /// Bring this session's window forward.
    func focus()
}

/// deviceId -> open session. Guarantees one session per device (opening an
/// already-open device just focuses it) and tracks the "active" session --
/// the one whose window was most recently key -- which app-level commands
/// (File > Reconnect, Settings' Reconnect, global hotkeys) act on.
final class SessionRegistry<Session: RegistrableSession> {
    private var sessions: [String: Session] = [:]
    /// Open order; the active session is moved to the end, so after the active
    /// one closes the most recently active remaining one takes over.
    private var recency: [String] = []
    private var observers: [UUID: () -> Void] = [:]
    private var observerOrder: [UUID] = []

    var isEmpty: Bool { sessions.isEmpty }
    var count: Int { sessions.count }

    /// Sessions in the order they were opened.
    private var openOrder: [String] = []
    var all: [Session] { openOrder.compactMap { sessions[$0] } }

    func session(for deviceId: String) -> Session? { sessions[deviceId] }

    var activeSession: Session? { recency.last.flatMap { sessions[$0] } }

    /// Returns the existing session for `deviceId` (focused, `created == false`)
    /// or registers a new one from `make` (`created == true`). The new/focused
    /// session becomes active.
    @discardableResult
    func openOrFocus(deviceId: String, make: () -> Session) -> (session: Session, created: Bool) {
        if let existing = sessions[deviceId] {
            markActive(deviceId)
            existing.focus()
            return (existing, false)
        }
        let session = make()
        precondition(session.deviceId == deviceId, "factory produced a session for a different device")
        sessions[deviceId] = session
        openOrder.append(deviceId)
        recency.append(deviceId)
        notify()
        return (session, true)
    }

    func markActive(_ deviceId: String) {
        guard sessions[deviceId] != nil, recency.last != deviceId else { return }
        recency.removeAll { $0 == deviceId }
        recency.append(deviceId)
        notify()
    }

    /// Unregisters; returns the removed session (nil if it wasn't open).
    @discardableResult
    func remove(deviceId: String) -> Session? {
        guard let removed = sessions.removeValue(forKey: deviceId) else { return nil }
        openOrder.removeAll { $0 == deviceId }
        recency.removeAll { $0 == deviceId }
        notify()
        return removed
    }

    /// Fires (synchronously, on the caller's thread) after every open,
    /// removal, or change of active session.
    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observerOrder.append(id)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
        observerOrder.removeAll { $0 == id }
    }

    private func notify() {
        observerOrder.compactMap { observers[$0] }.forEach { $0() }
    }
}
