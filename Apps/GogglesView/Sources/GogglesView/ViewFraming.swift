#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

enum FramingAspect: String, CaseIterable, Identifiable {
    case fit, fill, r16x9, r4x3, r1x1, r9x16
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return L("Fit")
        case .fill: return L("Fill")
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r9x16: return "9:16"
        }
    }
    /// Width/height of the crop window; nil = use the whole view.
    var ratio: CGFloat? {
        switch self {
        case .fit, .fill: return nil
        case .r16x9: return 16.0 / 9
        case .r4x3: return 4.0 / 3
        case .r1x1: return 1
        case .r9x16: return 9.0 / 16
        }
    }
}

enum FramingGrid: String, CaseIterable, Identifiable {
    case off, thirds, cross
    var id: String { rawValue }
    var title: String { self == .off ? L("Off") : self == .thirds ? L("Thirds") : L("Center cross") }
}

/// Pure geometry, kept free of AppKit state so it is unit-testable.
enum FramingGeometry {
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    static func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomRange.lowerBound), zoomRange.upperBound) }

    /// Pan is normalized to -1...1 where ±1 is the furthest shift that still
    /// keeps the zoomed picture covering the crop window; no pan at zoom 1.
    static func clampPan(_ p: CGFloat, zoom: CGFloat) -> CGFloat {
        zoom <= 1 ? 0 : min(max(p, -1), 1)
    }

    /// Largest rect of `ratio` (w/h) centered in `size`; whole rect when nil.
    static func cropRect(in size: CGSize, ratio: CGFloat?) -> CGRect {
        guard let ratio, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let w = min(size.width, size.height * ratio)
        let h = w / ratio
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Translation in points for a normalized pan.
    static func offset(pan: CGFloat, zoom: CGFloat, extent: CGFloat) -> CGFloat {
        clampPan(pan, zoom: zoom) * (zoom - 1) * extent / 2
    }

    /// New normalized pan after dragging the picture by `delta` points.
    static func pan(_ pan: CGFloat, dragging delta: CGFloat, zoom: CGFloat, extent: CGFloat) -> CGFloat {
        guard zoom > 1, extent > 0 else { return 0 }
        return clampPan(pan + delta / ((zoom - 1) * extent / 2), zoom: zoom)
    }

    /// Line segments (start, end) for the grid, inside `rect`.
    static func gridLines(in rect: CGRect, mode: FramingGrid) -> [(CGPoint, CGPoint)] {
        let fractions: [CGFloat]
        switch mode {
        case .off: return []
        case .thirds: fractions = [1.0 / 3, 2.0 / 3]
        case .cross: fractions = [0.5]
        }
        var out: [(CGPoint, CGPoint)] = []
        for f in fractions {
            let x = rect.minX + rect.width * f, y = rect.minY + rect.height * f
            out.append((CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: rect.maxY)))
            out.append((CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)))
        }
        return out
    }
}

enum FramingPrefs {
    static let aspectKey = "framingAspect"
    static let zoomKey = "framingZoom"
    static let panXKey = "framingPanX"
    static let panYKey = "framingPanY"
    static let gridKey = "framingGrid"
    static let brightnessKey = "colorBrightness"
    static let contrastKey = "colorContrast"
    static let saturationKey = "colorSaturation"

    private static var d: UserDefaults { .standard }
    private static func num(_ key: String, _ def: CGFloat) -> CGFloat {
        (d.object(forKey: key) as? Double).map { CGFloat($0) } ?? def
    }

    static var aspect: FramingAspect { FramingAspect(rawValue: d.string(forKey: aspectKey) ?? "") ?? .fit }
    static var grid: FramingGrid { FramingGrid(rawValue: d.string(forKey: gridKey) ?? "") ?? .off }
    static var zoom: CGFloat {
        get { FramingGeometry.clampZoom(num(zoomKey, 1)) }
        set { d.set(Double(FramingGeometry.clampZoom(newValue)), forKey: zoomKey) }
    }
    static var panX: CGFloat {
        get { FramingGeometry.clampPan(num(panXKey, 0), zoom: zoom) }
        set { d.set(Double(newValue), forKey: panXKey) }
    }
    static var panY: CGFloat {
        get { FramingGeometry.clampPan(num(panYKey, 0), zoom: zoom) }
        set { d.set(Double(newValue), forKey: panYKey) }
    }
    static var brightness: CGFloat { num(brightnessKey, 0) }
    static var contrast: CGFloat { num(contrastKey, 1) }
    static var saturation: CGFloat { num(saturationKey, 1) }

    static func resetView() {
        for k in [zoomKey, panXKey, panYKey] { d.removeObject(forKey: k) }
    }
    static func resetAll() {
        for k in [aspectKey, zoomKey, panXKey, panYKey, gridKey, brightnessKey, contrastKey, saturationKey] {
            d.removeObject(forKey: k)
        }
    }

    /// nil when all adjustments are neutral (no filter cost).
    static func colorFilters() -> [CIFilter]? {
        if RaceModePrefs.enabled { return nil }
        var filters: [CIFilter] = []
        if brightness != 0 || contrast != 1 || saturation != 1, let f = CIFilter(name: "CIColorControls") {
            f.setValue(brightness, forKey: kCIInputBrightnessKey)
            f.setValue(contrast, forKey: kCIInputContrastKey)
            f.setValue(saturation, forKey: kCIInputSaturationKey)
            filters.append(f)
        }
        if LookPrefs.applyPreview, let lut = LUTLibrary.currentFilter() { filters.append(lut) }
        return filters.isEmpty ? nil : filters
    }
}

/// Freeze flag (deliberately not persisted: relaunching frozen is a trap).
/// One per `DecodeSession` so each goggles window freezes independently;
/// `shared` remains for hosts without a session-specific instance.
final class FreezeState: ObservableObject {
    static let shared = FreezeState()
    private let lock = NSLock()
    private var _frozen = false
    @Published private(set) var isFrozen = false

    /// Thread-safe, for the decode thread.
    var frozenNow: Bool { lock.lock(); defer { lock.unlock() }; return _frozen }

    func toggle() { set(!frozenNow) }
    func set(_ v: Bool) {
        lock.lock(); _frozen = v; lock.unlock()
        DispatchQueue.main.async { self.isFrozen = v }
    }
}

/// Display layer that drops frames while frozen. Recorder/streamer consumers
/// are separate `SampleBufferRendering`s, so they keep receiving everything.
/// After unfreezing, non-sync frames are dropped until the next keyframe so
/// the decoder never sees a P-frame whose references were skipped.
final class FreezableDisplayLayer: AVSampleBufferDisplayLayer {
    var freezeState: FreezeState = .shared
    private var waitingForKeyframe = false
    private let gate = NSLock()

    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        gate.lock()
        if freezeState.frozenNow {
            waitingForKeyframe = true
            gate.unlock()
            return
        }
        if waitingForKeyframe {
            if Self.isSync(sampleBuffer) { waitingForKeyframe = false } else { gate.unlock(); return }
        }
        gate.unlock()
        super.enqueue(sampleBuffer)
    }

    private static func isSync(_ sb: CMSampleBuffer) -> Bool {
        Recorder.isKeyframe(sb)
    }
}

struct FreezeControl: View {
    @ObservedObject var state: FreezeState
    var body: some View {
        Button { state.toggle() } label: {
            Image(systemName: state.isFrozen ? "play.fill" : "pause.fill")
                .foregroundStyle(state.isFrozen ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.shift, .command])
        .help(state.isFrozen ? L("Resume video (⇧⌘F)") : L("Freeze video (⇧⌘F); recording and streaming continue"))
        .accessibilityLabel(state.isFrozen ? L("Resume video") : L("Freeze video"))
        .accessibilityHint("Recording and streaming continue while frozen")
        .accessibilityIdentifier("freezeButton")
    }
}

struct FramingSettingsSection: View {
    @AppStorage(FramingPrefs.aspectKey) private var aspect = FramingAspect.fit.rawValue
    @AppStorage(FramingPrefs.zoomKey) private var zoom = 1.0
    @AppStorage(FramingPrefs.gridKey) private var grid = FramingGrid.off.rawValue
    @AppStorage(FramingPrefs.brightnessKey) private var brightness = 0.0
    @AppStorage(FramingPrefs.contrastKey) private var contrast = 1.0
    @AppStorage(FramingPrefs.saturationKey) private var saturation = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Framing and color").font(.headline)
            Picker("Aspect", selection: $aspect) {
                ForEach(FramingAspect.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            slider(L("Zoom"), $zoom, 1...4, format: "%.1fx")
            Picker("Grid", selection: $grid) {
                ForEach(FramingGrid.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            slider(L("Brightness"), $brightness, -0.5...0.5, format: "%+.2f")
            slider(L("Contrast"), $contrast, 0.5...2, format: "%.2f")
            slider(L("Saturation"), $saturation, 0...2, format: "%.2f")
            Button("Reset") { FramingPrefs.resetAll() }
            Text("Scroll or pinch to zoom, drag to pan, double-click to reset. Affects the main and capture windows only; recordings and streams use Output framing below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value.wrappedValue))
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 48, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
#endif
