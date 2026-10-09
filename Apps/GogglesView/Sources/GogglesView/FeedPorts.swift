import Foundation

// Several goggles on one Mac need separate network outputs. Each open goggles window gets a "slot"
// (0, 1, 2, ...: the lowest free number, kept while the window is open). SRT and UDP use the port in
// Settings plus the slot, so the first window is unchanged; NDI adds the slot to the source name.

enum FeedPortPrefs {
    static let perFeedKey = "perFeedOutputs"
    /// On by default: slot 0 keeps the configured port, so one window behaves exactly as before.
    static var perFeed: Bool { UserDefaults.standard.object(forKey: perFeedKey) as? Bool ?? true }
}

struct FeedSlotAllocator {
    private(set) var slots: [String: Int] = [:]  // deviceId -> slot

    mutating func assign(_ deviceId: String) -> Int {
        if let s = slots[deviceId] { return s }
        let used = Set(slots.values)
        let s = (0...).first { !used.contains($0) }!
        slots[deviceId] = s
        return s
    }

    mutating func release(_ deviceId: String) { slots.removeValue(forKey: deviceId) }
    func slot(_ deviceId: String) -> Int? { slots[deviceId] }
}

enum FeedPorts {
    /// `base + slot`, or `base` when per-feed outputs are off. Past 65535 it wraps back below the base
    /// range rather than failing: a clamped port would silently collide with the last window's.
    static func port(base: Int, slot: Int, perFeed: Bool = true) -> Int {
        guard perFeed, slot > 0 else { return base }
        let p = base + slot
        return p <= 65535 ? p : max(1024, base - slot)
    }

    /// NDI sender names must be unique on the network. The first window keeps the plain name.
    static func ndiName(base: String, slot: Int, perFeed: Bool = true) -> String {
        guard perFeed, slot > 0 else { return base }
        let suffix = " \(slot + 1)"
        return String(base.prefix(max(1, 63 - suffix.count))) + suffix
    }
}

/// Process-wide slot table. Main thread only.
final class FeedSlots {
    static let shared = FeedSlots()
    private var allocator = FeedSlotAllocator()
    private var byDecode: [ObjectIdentifier: String] = [:]

    @discardableResult
    func assign(deviceId: String, decode: AnyObject) -> Int {
        byDecode[ObjectIdentifier(decode)] = deviceId
        return allocator.assign(deviceId)
    }

    func release(deviceId: String, decode: AnyObject) {
        byDecode[ObjectIdentifier(decode)] = nil
        allocator.release(deviceId)
    }

    func slot(deviceId: String) -> Int { allocator.slot(deviceId) ?? 0 }
    func slot(decode: AnyObject) -> Int { byDecode[ObjectIdentifier(decode)].map(slot(deviceId:)) ?? 0 }
}

// MARK: OBS sources for every feed

enum OBSFeedProtocol: String, CaseIterable { case srt, udp }

struct OBSFeedSource: Equatable {
    let name: String
    let url: String
}

enum OBSFeedSources {
    /// Where OBS must reach this Mac when GogglesView listens (SRT listener mode).
    static func gogglesHost(obsHost: String) -> String {
        let h = obsHost.trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "localhost", "127.0.0.1", "::1", "[::1]"].contains(h) ? "127.0.0.1" : ProcessInfo.processInfo.hostName
    }

    /// The OBS Media Source URL that receives what the matching GogglesView output sends.
    /// SRT listener: OBS calls GogglesView. SRT caller: GogglesView calls out, so OBS listens.
    /// UDP: GogglesView sends to the host in Settings, so OBS listens.
    static func url(proto: OBSFeedProtocol, srtMode: SRTMode, latencyMs: Int, port: Int, obsHost: String) -> String {
        switch proto {
        case .srt:
            switch srtMode {
            case .listener: return "srt://\(gogglesHost(obsHost: obsHost)):\(port)?mode=caller&latency=\(latencyMs * 1000)"
            case .caller: return "srt://0.0.0.0:\(port)?mode=listener&latency=\(latencyMs * 1000)"
            }
        case .udp:
            return "udp://0.0.0.0:\(port)?fifo_size=1000000&overrun_nonfatal=1"
        }
    }

    /// One source per feed, named after the feed. Duplicate or empty names get the slot appended so
    /// OBS never merges two feeds into one input.
    static func sources(feeds: [(name: String, slot: Int)], proto: OBSFeedProtocol, srtMode: SRTMode,
                        latencyMs: Int, srtBase: Int, udpBase: Int, perFeed: Bool, obsHost: String) -> [OBSFeedSource] {
        var seen = Set<String>()
        return feeds.map { f in
            var name = "GogglesView \(f.name)".trimmingCharacters(in: .whitespaces)
            if !seen.insert(name).inserted { name += " (\(f.slot + 1))"; seen.insert(name) }
            let base = proto == .srt ? srtBase : udpBase
            let port = FeedPorts.port(base: base, slot: f.slot, perFeed: perFeed)
            return OBSFeedSource(name: name, url: url(proto: proto, srtMode: srtMode, latencyMs: latencyMs, port: port, obsHost: obsHost))
        }
    }

    /// OBS `ffmpeg_source` settings (the Media Source). Unverified against a real OBS install.
    static func inputSettings(url: String) -> [String: Any] {
        ["input": url, "is_local_file": false, "close_when_inactive": false,
         "restart_on_activate": false, "clear_on_media_end": false, "reconnect_delay_sec": 2,
         "hw_decode": true]
    }
}
