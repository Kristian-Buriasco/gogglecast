import Foundation

/// The most recent SPS, PPS and IDR slice of a device's live stream, kept so
/// a subscriber that joins an already-live pipeline (XPC reconnect, second
/// window, app relaunch inside the linger) can be brought up with a format
/// description and a first picture instead of waiting for the next IDR.
/// Holds at most one IDR (~100-300 KB). Pure value type; owned and mutated
/// only on `HelperService.stateQueue`.
struct StreamHeadCache {
    struct Entry: Equatable {
        let data: Data
        let nalType: UInt8
        let isParameterSet: Bool
    }

    private var sps: Data?
    private var pps: Data?
    private var idr: Data?

    /// Records a NAL as delivered live. SPS (7), PPS (8) and IDR (5) replace
    /// the previous entry of the same type; everything else is ignored.
    mutating func record(nal: Data, nalType: UInt8) {
        switch nalType {
        case 7: sps = nal
        case 8: pps = nal
        case 5: idr = nal
        default: break
        }
    }

    /// Drop everything (reconnect, gate re-arm, pipeline end). A subscriber
    /// joining while invalid gets nothing and waits for live delivery.
    mutating func invalidate() {
        sps = nil
        pps = nil
        idr = nil
    }

    /// True when a decoder could be started from the cache.
    var isReplayable: Bool { idr != nil && (sps != nil || pps != nil) }

    /// Entries in live-delivery order: SPS, PPS, then IDR. Empty unless
    /// replayable (an IDR without parameter sets is useless).
    func replay() -> [Entry] {
        guard isReplayable, let idr else { return [] }
        var out: [Entry] = []
        if let sps { out.append(Entry(data: sps, nalType: 7, isParameterSet: true)) }
        if let pps { out.append(Entry(data: pps, nalType: 8, isParameterSet: true)) }
        out.append(Entry(data: idr, nalType: 5, isParameterSet: false))
        return out
    }
}

/// Bounded exponential backoff for re-attempting a failed hardware bring-up
/// while subscribers still want video: 1s, 2s, 4s, 8s, then capped at 10s.
struct RetryBackoff {
    static let base: TimeInterval = 1.0
    static let cap: TimeInterval = 10.0

    private(set) var attempt = 0

    /// Delay for the next retry; advances the attempt counter.
    mutating func nextDelay() -> TimeInterval {
        let d = Self.delay(forAttempt: attempt)
        attempt += 1
        return d
    }

    mutating func reset() { attempt = 0 }

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let exp = min(max(attempt, 0), 16)
        return min(cap, base * Double(1 << exp))
    }
}
