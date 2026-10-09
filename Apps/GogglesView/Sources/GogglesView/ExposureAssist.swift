import Foundation
import CoreImage
import CoreVideo
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// Zebra stripes and focus peaking: shooting aids drawn over the preview. They never touch the
// recorded or streamed picture. The analysis runs on a small copy of the frame at a limited
// rate, so the cost stays low and does not depend on the goggles' resolution.

enum ExposurePrefs {
    static let zebraKey = "exposureZebra"
    static let zebraLevelKey = "exposureZebraLevel"
    static let peakingKey = "exposurePeaking"
    static let peakingSensitivityKey = "exposurePeakingSensitivity"
    static let peakingColorKey = "exposurePeakingColor"

    static func zebra(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: zebraKey) }
    static func zebraLevel(_ d: UserDefaults = .standard) -> Int {
        let v = d.object(forKey: zebraLevelKey) as? Int ?? 95
        return min(max(v, 50), 100)
    }
    static func peaking(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: peakingKey) }
    static func setZebra(_ on: Bool, defaults d: UserDefaults = .standard) { d.set(on, forKey: zebraKey) }
    static func setPeaking(_ on: Bool, defaults d: UserDefaults = .standard) { d.set(on, forKey: peakingKey) }
    static func sensitivity(_ d: UserDefaults = .standard) -> PeakingSensitivity {
        PeakingSensitivity(rawValue: d.string(forKey: peakingSensitivityKey) ?? "") ?? .medium
    }
    static func color(_ d: UserDefaults = .standard) -> PeakingColor {
        PeakingColor(rawValue: d.string(forKey: peakingColorKey) ?? "") ?? .red
    }

    /// What the preview should draw now. Race mode turns the aids off with the other overlays.
    static func current(raceMode: Bool = RaceModePrefs.enabled, defaults d: UserDefaults = .standard) -> ExposureSettings? {
        guard !raceMode else { return nil }
        let z = zebra(d), p = peaking(d)
        guard z || p else { return nil }
        return ExposureSettings(zebra: z, zebraLevel: zebraLevel(d), peaking: p, sensitivity: sensitivity(d), color: color(d))
    }
}

enum PeakingSensitivity: String, CaseIterable {
    case low, medium, high

    /// Luma gradient (0...4 scale of a 3x3 Sobel on 0...1 luma) above which a pixel counts as in focus.
    var threshold: Float {
        switch self {
        case .low: return 0.55
        case .medium: return 0.38
        case .high: return 0.22
        }
    }
}

enum PeakingColor: String, CaseIterable {
    case red, green, yellow, white

    /// Premultiplied BGRA (opaque).
    var bgra: (UInt8, UInt8, UInt8, UInt8) {
        switch self {
        case .red: return (40, 40, 255, 255)
        case .green: return (60, 255, 60, 255)
        case .yellow: return (40, 235, 255, 255)
        case .white: return (255, 255, 255, 255)
        }
    }
}

struct ExposureSettings: Equatable {
    var zebra: Bool
    /// Percent of full white at which stripes start (100 means clipping).
    var zebraLevel: Int
    var peaking: Bool
    var sensitivity: PeakingSensitivity
    var color: PeakingColor
}

enum ExposureAnalysis {
    /// Width of the analysis copy; height follows the picture's aspect.
    static let analysisWidth = 640

    /// Luma (0...1) at which stripes start. 100 is "clipping": the last few steps below white count.
    static func zebraThreshold(level: Int) -> Float {
        level >= 100 ? 0.97 : Float(min(max(level, 0), 99)) / 100
    }

    @inline(__always) private static func luma(_ p: UnsafePointer<UInt8>) -> Float {
        // BGRA, Rec.709 weights on the encoded values.
        (0.0722 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.2126 * Float(p[2])) / 255
    }

    /// Builds the overlay for one BGRA frame: transparent everywhere except stripes over bright
    /// areas and a colour over sharp edges. Output is premultiplied BGRA, same size as the input.
    /// `phase` shifts the stripes so they march slowly and read as an overlay, not as picture.
    static func overlay(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                        settings: ExposureSettings, phase: Int = 0) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        guard width >= 3, height >= 3 else { return out }
        let zebraAt = zebraThreshold(level: settings.zebraLevel)
        let peak = settings.sensitivity.threshold
        let (cb, cg, cr, ca) = settings.color.bgra

        // Luma plane, once; both aids read it.
        var y = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let line = bgra + row * bytesPerRow
            for col in 0..<width { y[row * width + col] = luma(line + col * 4) }
        }

        for row in 0..<height {
            for col in 0..<width {
                let i = row * width + col
                var painted = false
                if settings.peaking, row > 0, col > 0, row < height - 1, col < width - 1 {
                    let a = y[i - width - 1], b = y[i - width], c = y[i - width + 1]
                    let d = y[i - 1], f = y[i + 1]
                    let g = y[i + width - 1], h = y[i + width], k = y[i + width + 1]
                    let gx = (c + 2 * f + k) - (a + 2 * d + g)
                    let gy = (g + 2 * h + k) - (a + 2 * b + c)
                    if (gx * gx + gy * gy).squareRoot() > peak {
                        let o = i * 4
                        out[o] = cb; out[o + 1] = cg; out[o + 2] = cr; out[o + 3] = ca
                        painted = true
                    }
                }
                if !painted, settings.zebra, y[i] >= zebraAt {
                    // Alternating dark and light diagonal bands read on any picture.
                    let o = i * 4
                    let light = ((col + row + phase) / 4) % 2 == 0
                    let v: UInt8 = light ? 200 : 0
                    out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = 200
                }
            }
        }
        return out
    }
}

/// Produces the overlay image from decoded frames, off the decode thread and at a limited rate.
final class ExposureAnalyzer {
    private let queue = DispatchQueue(label: "gogglesview.exposure", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var busy = false
    private var lastRun: UInt64 = 0
    private var frameCounter = 0
    /// Minimum gap between analyses.
    var minInterval: UInt64 = 66_000_000 // about 15 per second

    /// Fed on the decode thread. Returns immediately; at most one analysis is in flight.
    /// `deliver` runs on the main queue with nil when the aids are off.
    func submit(_ frame: CVPixelBuffer, settings: ExposureSettings?, deliver: @escaping (CGImage?) -> Void) {
        guard let settings else {
            lock.lock(); let was = lastRun != 0; lastRun = 0; lock.unlock()
            if was { DispatchQueue.main.async { deliver(nil) } }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if busy || now &- lastRun < minInterval { lock.unlock(); return }
        busy = true; lastRun = now
        frameCounter &+= 1
        let counter = frameCounter
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let image = self.render(frame, settings: settings, phase: counter / 3)
            self.lock.lock(); self.busy = false; self.lock.unlock()
            DispatchQueue.main.async { deliver(image) }
        }
    }

    private func render(_ frame: CVPixelBuffer, settings: ExposureSettings, phase: Int) -> CGImage? {
        let srcW = CVPixelBufferGetWidth(frame), srcH = CVPixelBufferGetHeight(frame)
        guard srcW > 0, srcH > 0 else { return nil }
        let w = ExposureAnalysis.analysisWidth
        let h = max(3, Int((Double(srcH) * Double(w) / Double(srcW)).rounded()))
        var small: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &small) == kCVReturnSuccess,
              let small else { return nil }
        let scaled = CIImage(cvPixelBuffer: frame)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(srcW), y: CGFloat(h) / CGFloat(srcH)))
        context.render(scaled, to: small)

        CVPixelBufferLockBaseAddress(small, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(small, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(small) else { return nil }
        let bytes = ExposureAnalysis.overlay(
            bgra: base.assumingMemoryBound(to: UInt8.self), width: w, height: h,
            bytesPerRow: CVPixelBufferGetBytesPerRow(small), settings: settings, phase: phase)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

#if canImport(SwiftUI) && canImport(AppKit)
struct ExposureSettingsSection: View {
    @AppStorage(ExposurePrefs.zebraKey) private var zebra = false
    @AppStorage(ExposurePrefs.zebraLevelKey) private var level = 95
    @AppStorage(ExposurePrefs.peakingKey) private var peaking = false
    @AppStorage(ExposurePrefs.peakingSensitivityKey) private var sensitivity = PeakingSensitivity.medium.rawValue
    @AppStorage(ExposurePrefs.peakingColorKey) private var color = PeakingColor.red.rawValue

    private var levelText: String { level >= 100 ? "100%" : "\(level)%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exposure and focus aids").font(.headline)
            Toggle("Zebra stripes", isOn: $zebra)
            HStack {
                Text("Stripes from").frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { Double(level) }, set: { level = Int($0.rounded()) }), in: 50...100, step: 5)
                    .disabled(!zebra)
                Text(verbatim: levelText).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Toggle("Focus peaking", isOn: $peaking)
            HStack {
                Picker("Sensitivity", selection: $sensitivity) {
                    Text("Low").tag(PeakingSensitivity.low.rawValue)
                    Text("Medium").tag(PeakingSensitivity.medium.rawValue)
                    Text("High").tag(PeakingSensitivity.high.rawValue)
                }
                Picker("Colour", selection: $color) {
                    Text("Red").tag(PeakingColor.red.rawValue)
                    Text("Green").tag(PeakingColor.green.rawValue)
                    Text("Yellow").tag(PeakingColor.yellow.rawValue)
                    Text("White").tag(PeakingColor.white.rawValue)
                }
            }
            .disabled(!peaking)
            Text("Stripes mark areas that are close to white, so you can see where highlights clip. Peaking colours sharp edges. Both only appear in the preview; recordings and streams are not changed. Race mode turns them off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
