import Foundation

/// Decides what to do while the decoder is stuck waiting for a keyframe that never comes
/// (after a decoder reset, a run of decode failures or dropped input). Pure: the caller
/// passes the clock, so the timing is unit-tested without sleeping.
///
/// First it asks the goggles for a fresh I-frame (and repeats that every `requestInterval`),
/// then, if nothing usable arrives within `escalateAfter`, it asks for a full reconnect.
/// Reconnects back off (doubling, capped) so a stream that really is dead is not hammered.
struct KeyframeRecoveryPolicy {
    enum Action: Equatable { case none, requestKeyframe, reconnect }

    let requestInterval: TimeInterval
    let escalateAfter: TimeInterval
    let maxReconnectInterval: TimeInterval

    private(set) var waitingSince: Date?
    private var lastRequestAt: Date?
    private var lastReconnectAt: Date?
    private var reconnectInterval: TimeInterval

    init(escalateAfter: TimeInterval = 3, requestInterval: TimeInterval = 1.5, maxReconnectInterval: TimeInterval = 24) {
        self.escalateAfter = escalateAfter
        self.requestInterval = requestInterval
        self.maxReconnectInterval = maxReconnectInterval
        self.reconnectInterval = escalateAfter
    }

    /// `waiting` is true only while there is a reason to expect video (the helper reports live)
    /// and the decoder still has no keyframe.
    mutating func update(waiting: Bool, now: Date) -> Action {
        guard waiting else {
            waitingSince = nil; lastRequestAt = nil; lastReconnectAt = nil
            reconnectInterval = escalateAfter
            return .none
        }
        guard let since = waitingSince else {
            waitingSince = now; lastRequestAt = now
            return .requestKeyframe
        }
        let reference = lastReconnectAt ?? since
        if now.timeIntervalSince(reference) >= reconnectInterval {
            lastReconnectAt = now; lastRequestAt = now
            reconnectInterval = min(reconnectInterval * 2, maxReconnectInterval)
            return .reconnect
        }
        if let last = lastRequestAt, now.timeIntervalSince(last) >= requestInterval {
            lastRequestAt = now
            return .requestKeyframe
        }
        return .none
    }
}
