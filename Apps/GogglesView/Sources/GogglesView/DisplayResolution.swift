import Foundation
import CoreGraphics

// Output resolution for a program output: lets GogglesView drop a 4K TV to 1080p so the Mac works less.
// The pure part (ModeInfo, DisplayModePicker, OutputResolution) is unit-tested; the real display is only
// touched through the DisplayConfigurator protocol, with kCGConfigureForAppOnly so macOS puts the mode
// back by itself when the app quits or crashes.

/// Stored in ProgramOutputConfig.resolution as its raw value; nil / unknown = Display default.
enum OutputResolution: String, CaseIterable {
    case displayDefault = "default"
    case p1080 = "1080p"
    case p720 = "720p"

    /// Pixel size to switch to, nil = never change anything.
    var target: (w: Int, h: Int)? {
        switch self {
        case .displayDefault: return nil
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        }
    }
    var label: String { target.map { "\($0.w)x\($0.h)" } ?? "" }
}

/// Plain copy of the CGDisplayMode fields we need.
struct ModeInfo: Equatable {
    var modeID: Int32
    var width: Int          // points
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var hz: Double
    var usable = true
    /// HiDPI: more pixels than points. A 1080p HiDPI mode renders 4K, so it does not lighten anything.
    var isHiDPI: Bool { pixelWidth > width }
}

enum DisplayModePicker {
    /// The mode with exactly the target pixel size: non-HiDPI first, then the refresh rate closest to `currentHz`
    /// (the higher one on a tie). nil when the display has no such mode. The main display is refused by
    /// DisplayResolutionManager, which knows the display; this only sees modes.
    static func pick(from modes: [ModeInfo], target: (w: Int, h: Int), currentHz: Double) -> ModeInfo? {
        let matches = modes.filter { $0.usable && $0.pixelWidth == target.w && $0.pixelHeight == target.h }
        let pool = matches.contains { !$0.isHiDPI } ? matches.filter { !$0.isHiDPI } : matches
        return pool.min {
            let a = abs($0.hz - currentHz), b = abs($1.hz - currentHz)
            return a != b ? a < b : $0.hz > $1.hz
        }
    }
}

protocol DisplayConfigurator {
    func isMain(_ display: UInt32) -> Bool
    func currentMode(_ display: UInt32) -> ModeInfo?
    func modes(_ display: UInt32) -> [ModeInfo]
    /// App-only, never permanent. Returns false when macOS refused.
    func set(_ mode: ModeInfo, on display: UInt32) -> Bool
}

enum ResolutionResult: Equatable {
    case applied(String)        // "1920x1080"
    case refusedMain
    case noMatchingMode(String)
    case failed
}

/// Remembers the original mode per display and puts it back. Main thread only.
final class DisplayResolutionManager {
    private let configurator: DisplayConfigurator
    private var originals: [UInt32: ModeInfo] = [:]
    private var applied: [UInt32: OutputResolution] = [:]

    init(configurator: DisplayConfigurator) { self.configurator = configurator }

    var changedDisplays: Set<UInt32> { Set(originals.keys) }

    /// Makes the displays match `desired` (display -> resolution; displayDefault or absent = original mode).
    /// Returns the outcome for every display that has a non-default request.
    @discardableResult
    func sync(_ desired: [UInt32: OutputResolution]) -> [UInt32: ResolutionResult] {
        for id in Array(applied.keys) where desired[id] != applied[id] { restore(id) }
        var results: [UInt32: ResolutionResult] = [:]
        for (id, res) in desired {
            guard let t = res.target else { continue }
            if applied[id] == res { results[id] = .applied(res.label); continue }
            results[id] = apply(id, res, t)
        }
        return results
    }

    func restoreAll() { for id in Array(applied.keys) { restore(id) } }

    private func apply(_ id: UInt32, _ res: OutputResolution, _ t: (w: Int, h: Int)) -> ResolutionResult {
        guard !configurator.isMain(id) else { return .refusedMain }   // never risk locking the user out
        guard let current = configurator.currentMode(id) else { return .failed }
        if current.pixelWidth == t.w && current.pixelHeight == t.h && !current.isHiDPI {
            applied[id] = res; return .applied(res.label)             // already there, nothing to restore
        }
        guard let mode = DisplayModePicker.pick(from: configurator.modes(id), target: t, currentHz: current.hz)
        else { return .noMatchingMode(res.label) }
        guard configurator.set(mode, on: id) else { return .failed }
        originals[id] = current
        applied[id] = res
        return .applied(res.label)
    }

    private func restore(_ id: UInt32) {
        if let orig = originals[id] { _ = configurator.set(orig, on: id) }
        originals[id] = nil
        applied[id] = nil
    }
}

struct CoreGraphicsDisplayConfigurator: DisplayConfigurator {
    private func cgModes(_ display: UInt32) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []
    }
    private func info(_ m: CGDisplayMode) -> ModeInfo {
        ModeInfo(modeID: m.ioDisplayModeID, width: m.width, height: m.height, pixelWidth: m.pixelWidth,
                 pixelHeight: m.pixelHeight, hz: m.refreshRate, usable: m.isUsableForDesktopGUI())
    }
    func isMain(_ display: UInt32) -> Bool { display == CGMainDisplayID() }
    func currentMode(_ display: UInt32) -> ModeInfo? { CGDisplayCopyDisplayMode(display).map(info) }
    func modes(_ display: UInt32) -> [ModeInfo] { cgModes(display).map(info) }
    func set(_ mode: ModeInfo, on display: UInt32) -> Bool {
        guard let m = cgModes(display).first(where: { $0.ioDisplayModeID == mode.modeID }) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        guard CGConfigureDisplayWithDisplayMode(cfg, display, m, nil) == .success else {
            CGCancelDisplayConfiguration(cfg); return false
        }
        // forAppOnly: not permanent, macOS restores the user's mode when this process ends.
        return CGCompleteDisplayConfiguration(cfg, .forAppOnly) == .success
    }
}
