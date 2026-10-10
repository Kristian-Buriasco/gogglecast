import Foundation
import CoreVideo

// Status of every open goggles for an event: connection health plus what the app can tell about the
// picture (black, frozen), the battery and the outputs. The operator overview, the program output,
// the menu-bar icon and the web status page all read the same snapshot.

enum FeedHealth: Int, Comparable { case good = 0, warning, bad
    static func < (a: FeedHealth, b: FeedHealth) -> Bool { a.rawValue < b.rawValue }
}

enum FeedIssue: Equatable {
    case lowBattery(Int), criticalBattery(Int), frozenPicture, blackPicture

    var severity: FeedHealth {
        switch self {
        case .criticalBattery: return .bad
        case .lowBattery, .frozenPicture, .blackPicture: return .warning
        }
    }

    var text: String {
        switch self {
        case .lowBattery(let p), .criticalBattery(let p): return L("Battery %lld%%", p)
        case .frozenPicture: return L("Picture not changing")
        case .blackPicture: return L("Black picture")
        }
    }

    /// Machine-readable name for the web status page.
    var code: String {
        switch self {
        case .lowBattery: return "low-battery"
        case .criticalBattery: return "critical-battery"
        case .frozenPicture: return "frozen"
        case .blackPicture: return "black"
        }
    }
}

enum EventRules {
    static let batteryWarn = 25
    static let batteryCritical = 10

    static func batteryIssue(_ percent: Int?) -> FeedIssue? {
        guard let p = percent else { return nil }
        if p < batteryCritical { return .criticalBattery(p) }
        if p < batteryWarn { return .lowBattery(p) }
        return nil
    }

    /// The worse of the connection health and every issue. Picture issues never turn a live feed red:
    /// a covered camera or a still scene is a question for the operator, not an outage.
    static func combine(connection: FeedHealth, issues: [FeedIssue]) -> FeedHealth {
        issues.reduce(connection) { max($0, $1.severity) }
    }

    /// Only a live feed can have a picture or battery problem worth showing; a lost one already says so.
    static func issues(live: Bool, battery: Int?, picture: PictureState) -> [FeedIssue] {
        guard live else { return [] }
        var out: [FeedIssue] = []
        if let b = batteryIssue(battery) { out.append(b) }
        switch picture {
        case .black: out.append(.blackPicture)
        case .frozen: out.append(.frozenPicture)
        case .ok, .unknown: break
        }
        return out
    }
}

// MARK: Picture watch

enum PictureState: Equatable { case unknown, ok, black, frozen }

/// One feed's picture watcher: feed it a small sample every couple of seconds.
struct PictureWatch {
    struct Sample: Equatable {
        var luma: Double        // 0...255 mean of the sampled pixels
        var signature: UInt64   // hash of the sampled pixels
    }

    static let blackLuma = 6.0
    static let blackSeconds: TimeInterval = 10
    static let frozenSeconds: TimeInterval = 15

    private var blackSince: Date?
    private var sameSince: Date?
    private var lastSignature: UInt64?
    private var lastSequence: UInt64?

    mutating func reset() { self = PictureWatch() }

    /// `sequence` is the decoded-frame counter: a picture that repeats while the counter advances is
    /// frozen; a counter that stands still is a stalled stream, which the connection state reports.
    mutating func observe(_ sample: Sample?, sequence: UInt64, now: Date) -> PictureState {
        defer { lastSequence = sequence }
        guard let sample else { reset(); return .unknown }
        if sample.luma < Self.blackLuma { blackSince = blackSince ?? now } else { blackSince = nil }
        let advancing = lastSequence.map { sequence > $0 } ?? false
        if let last = lastSignature, last == sample.signature {
            if advancing { sameSince = sameSince ?? now }
        } else {
            sameSince = nil
        }
        lastSignature = sample.signature
        if let b = blackSince, now.timeIntervalSince(b) >= Self.blackSeconds { return .black }
        if let f = sameSince, now.timeIntervalSince(f) >= Self.frozenSeconds { return .frozen }
        return .ok
    }

    /// A coarse look at the luma plane: every 16th pixel of every 16th row. Cheap enough to run on the
    /// main queue every couple of seconds. Nil for pixel formats it does not understand.
    static func sample(_ buffer: CVPixelBuffer, step: Int = 16) -> Sample? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bytesPerSample: Int
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: bytesPerSample = 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: bytesPerSample = 2
        default: return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard w > 0, h > 0 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, count = 0.0
        var hash: UInt64 = 0xcbf29ce484222325
        for y in stride_(0, h, step) {
            for x in stride_(0, w, step) {
                // 10-bit samples are stored left-aligned in 16 bits: the high byte is an 8-bit luma.
                let v = p[y * stride + x * bytesPerSample + (bytesPerSample - 1)]
                sum += Double(v); count += 1
                hash = (hash ^ UInt64(v)) &* 0x100000001b3
            }
        }
        return count > 0 ? Sample(luma: sum / count, signature: hash) : nil
    }

    private static func stride_(_ from: Int, _ to: Int, _ by: Int) -> StrideTo<Int> { stride(from: from, to: to, by: max(1, by)) }
}

// MARK: Outputs

struct OutputChip: Equatable {
    enum State: Equatable { case off, waiting, on, error }
    let name: String   // "SRT", "UDP", "NDI"
    var state: State
}

enum EventOutputKind: String, CaseIterable {
    case srt = "SRT", udp = "UDP", ndi = "NDI"
    var prefKey: String { "eventOutput" + rawValue }

    /// Which outputs "Start all outputs" starts. SRT is the one OBS reads, so it is on by default.
    static func enabled(_ k: EventOutputKind, _ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: k.prefKey) as? Bool ?? (k == .srt)
    }
}

extension Notification.Name {
    /// Posted (object nil = every window) to start or stop the outputs chosen for "Start all outputs".
    static let gogglesStartAllOutputs = Notification.Name("GogglesStartAllOutputs")
    static let gogglesStopAllOutputs = Notification.Name("GogglesStopAllOutputs")
    static let eventStatusChanged = Notification.Name("GogglesEventStatusChanged")
}

// MARK: Web snapshot

/// What the web status page may show: names, state, fps, battery, issues and outputs. Never a device id
/// or serial number.
enum EventStatusJSON {
    static func data(rows: [OverviewRow], now: Date = Date()) -> Data {
        let feeds: [[String: Any]] = rows.map { r in
            var f: [String: Any] = [
                "name": r.name, "status": r.status, "live": r.isLive,
                "health": r.health == .good ? "good" : (r.health == .warning ? "warning" : "bad"),
                "issues": r.issues.map(\.code), "issueText": r.issues.map(\.text),
                "outputs": r.outputs.map { ["name": $0.name, "state": "\($0.state)"] },
            ]
            if let fps = r.fps { f["fps"] = fps }
            if let b = r.battery { f["battery"] = b }
            return f
        }
        let obj: [String: Any] = ["updated": ISO8601DateFormatter().string(from: now), "feeds": feeds]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// Latest snapshot for the web server, which runs on its own queue.
enum WebStatusStore {
    private static let lock = NSLock()
    private static var snapshot = EventStatusJSON.data(rows: [])
    static var latest: Data { lock.lock(); defer { lock.unlock() }; return snapshot }
    static func set(_ d: Data) { lock.lock(); snapshot = d; lock.unlock() }
}
