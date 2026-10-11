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

    /// `escalateAfter` is 8 s: the pipeline opens its keyframe gate on its own after 2.5 s without one, and a reconnect
    /// before that has had time to show a picture only throws the resumed stream away again (seen on live goggles:
    /// live at 47.468, reconnect at 47.852).
    init(escalateAfter: TimeInterval = 8, requestInterval: TimeInterval = 1.5, maxReconnectInterval: TimeInterval = 32) {
        self.escalateAfter = escalateAfter
        self.requestInterval = requestInterval
        self.maxReconnectInterval = maxReconnectInterval
        self.reconnectInterval = escalateAfter
    }

    /// A real picture is on screen again: the next stall starts with the short interval.
    mutating func pictureShown() {
        waitingSince = nil; lastRequestAt = nil; lastReconnectAt = nil
        reconnectInterval = escalateAfter
    }

    /// `waiting` is true only while there is a reason to expect video (the helper reports live)
    /// and the decoder still has no keyframe.
    mutating func update(waiting: Bool, now: Date) -> Action {
        guard waiting else {
            // Keep the backoff: a reconnect itself ends the "waiting" state for a moment, and resetting here made a
            // stream without keyframe reconnect every 8 s forever (seen on live goggles). `pictureShown()` resets it.
            waitingSince = nil; lastRequestAt = nil; lastReconnectAt = nil
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
