import Foundation
import CoreImage
import CoreVideo
import IOSurface
#if canImport(AppKit)
import AppKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - .cube LUT

/// A 3D color lookup table in the Adobe/Resolve `.cube` format (red varies fastest).
struct CubeLUT: Equatable {
    enum ParseError: Error, Equatable { case no3DTable, badSize, badData(line: Int), wrongCount(expected: Int, got: Int), tooLarge }

    /// Largest accepted file (a 129^3 table is ~50 MB of text) and value count.
    static let maxFileBytes = 64 * 1024 * 1024
    static let maxSize = 129
    static let maxValues = maxSize * maxSize * maxSize * 3

    let size: Int
    /// size³ RGBA floats, normalized to 0...1, red index fastest.
    let rgba: [Float]

    static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        var saw1D = false
        for (i, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch parts[0] {
            case "TITLE": continue
            case "LUT_1D_SIZE": saw1D = true
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...maxSize).contains(n) else { throw ParseError.badSize }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4, let a = Float(parts[1]), let b = Float(parts[2]), let c = Float(parts[3]),
                      a.isFinite, b.isFinite, c.isFinite else { throw ParseError.badData(line: i + 1) }
                if parts[0] == "DOMAIN_MIN" { domainMin = [a, b, c] } else { domainMax = [a, b, c] }
            default:
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    if parts[0].first?.isLetter == true { continue } // unknown keyword
                    throw ParseError.badData(line: i + 1)
                }
                guard r.isFinite, g.isFinite, b.isFinite else { throw ParseError.badData(line: i + 1) }
                values.append(contentsOf: [r, g, b])
                // Stop as soon as there is more data than the declared (or maximum possible) table.
                let limit = size > 0 ? size * size * size * 3 : maxValues
                if values.count > limit { throw ParseError.wrongCount(expected: limit / 3, got: values.count / 3) }
            }
        }
        guard size > 0 else { throw saw1D ? ParseError.no3DTable : ParseError.badSize }
        let expected = size * size * size * 3
        guard values.count == expected else { throw ParseError.wrongCount(expected: expected / 3, got: values.count / 3) }
        var rgba = [Float](); rgba.reserveCapacity(size * size * size * 4)
        for p in stride(from: 0, to: values.count, by: 3) {
            for c in 0..<3 {
                let span = domainMax[c] - domainMin[c]
                let v = span > 0 ? (values[p + c] - domainMin[c]) / span : values[p + c]
                rgba.append(min(max(v, 0), 1))
            }
            rgba.append(1)
        }
        return CubeLUT(size: size, rgba: rgba)
    }

    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var identities: [Int: [Float]] = [:]

    /// The identity cube (RGBA floats, red fastest) for `size`, built once per size.
    static func identityCube(size n: Int) -> [Float] {
        identityLock.lock(); defer { identityLock.unlock() }
        if let c = identities[n] { return c }
        var out = [Float](); out.reserveCapacity(n * n * n * 4)
        let d = Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n { out += [Float(r) / d, Float(g) / d, Float(b) / d, 1] } } }
        identities[n] = out
        return out
    }

    /// Cube data for CIColorCube, faded between identity (0) and the full look (1).
    func cubeData(intensity: Float) -> Data {
        let t = min(max(intensity, 0), 1)
        var out = rgba
        if t < 1 {
            let ident = Self.identityCube(size: size)
            for i in 0..<out.count where i % 4 != 3 { out[i] = ident[i] + (rgba[i] - ident[i]) * t }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - LUT library and look prefs

enum LookPrefs {
    static let nameKey = "lutName"
    static let intensityKey = "lutIntensity"
    static let previewKey = "lutApplyPreview"
    static let outputKey = "lutApplyOutput"

    private static var d: UserDefaults { .standard }
    static var name: String { d.string(forKey: nameKey) ?? "" }
    static var intensity: Double { min(max(d.object(forKey: intensityKey) as? Double ?? 1, 0), 1) }
    static var applyPreview: Bool { d.object(forKey: previewKey) as? Bool ?? true }
    static var applyOutput: Bool { d.object(forKey: outputKey) as? Bool ?? false }
}

enum LUTLibrary {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GogglesView/LUTs", isDirectory: true)
    }()

    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Reads a .cube file, refusing anything over `CubeLUT.maxFileBytes` before loading it.
    static func readText(_ url: URL) throws -> String {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CubeLUT.maxFileBytes else { throw CubeLUT.ParseError.tooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Validates and copies a .cube file into the library; returns the stored name.
    /// Parses the whole table, so call it off the main thread.
    @discardableResult
    static func importFile(_ url: URL) throws -> String {
        let text = try readText(url)
        _ = try CubeLUT.parse(text)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        try text.write(to: directory.appendingPathComponent(name + ".cube"), atomically: true, encoding: .utf8)
        return name
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".cube"))
    }

    private static let lock = NSLock()
    private static var cache: (key: String, lut: CubeLUT)?
    private static var failedKey: String?
    private static var filterCache: (key: String, filter: CIFilter)?
    /// Number of times a .cube file was actually read and parsed (tests).
    nonisolated(unsafe) private(set) static var parseCount = 0

    private static func key(for name: String) -> (url: URL, key: String) {
        let url = directory.appendingPathComponent(name + ".cube")
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return (url, "\(directory.path)/\(name)@\(mtime)")
    }

    /// Caller holds `lock`.
    private static func loadLocked(_ name: String, _ k: (url: URL, key: String)) -> CubeLUT? {
        if let c = cache, c.key == k.key { return c.lut }
        if failedKey == k.key { return nil } // invalid file: don't re-read it every frame
        parseCount += 1
        guard let text = try? readText(k.url), let lut = try? CubeLUT.parse(text) else {
            failedKey = k.key; return nil
        }
        cache = (k.key, lut); failedKey = nil; filterCache = nil
        return lut
    }

    static func load(_ name: String) -> CubeLUT? {
        guard !name.isEmpty else { return nil }
        let k = key(for: name)
        lock.lock(); defer { lock.unlock() }
        return loadLocked(name, k)
    }

    /// A ready-to-use CIFilter for the selected look, nil when none is selected or it can't be read.
    /// The configured filter is cached per (file version, intensity); callers get their own copy so
    /// setting the input image is safe across threads.
    static func currentFilter() -> CIFilter? {
        let name = LookPrefs.name, intensity = LookPrefs.intensity
        guard !name.isEmpty else { return nil }
        let k = key(for: name)
        lock.lock(); defer { lock.unlock() }
        guard let lut = loadLocked(name, k) else { return nil }
        let fkey = "\(k.key)#\(intensity)"
        if let c = filterCache, c.key == fkey { return c.filter.copy() as? CIFilter }
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(lut.size, forKey: "inputCubeDimension")
        f.setValue(lut.cubeData(intensity: Float(intensity)), forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.itur_709), forKey: "inputColorSpace")
        filterCache = (fkey, f)
        return f.copy() as? CIFilter
    }
}

// MARK: - Output framing (recordings, replay, streams)

/// Own crop for everything that leaves the app, independent of the in-app preview framing.
enum OutputFramingPrefs {
    static let enabledKey = "outFramingEnabled"
    static let aspectKey = "outFramingAspect"
    static let zoomKey = "outFramingZoom"
    static let panXKey = "outFramingPanX"
    static let panYKey = "outFramingPanY"

    private static var d: UserDefaults { .standard }
    static var enabled: Bool { d.bool(forKey: enabledKey) }
    static var aspect: FramingAspect { FramingAspect(rawValue: d.string(forKey: aspectKey) ?? "") ?? .fit }
    static var zoom: CGFloat { FramingGeometry.clampZoom(CGFloat(d.object(forKey: zoomKey) as? Double ?? 1)) }
    static var panX: CGFloat { CGFloat(min(max(d.object(forKey: panXKey) as? Double ?? 0, -1), 1)) }
    static var panY: CGFloat { CGFloat(min(max(d.object(forKey: panYKey) as? Double ?? 0, -1), 1)) }
}

enum OutputGeometry {
    /// The part of a `size` picture that becomes the output, and the output's pixel size (even, for H.264).
    /// `rect` is in image space with y up; pan ±1 slides the window to the edge of the crop.
    static func plan(size: CGSize, ratio: CGFloat?, zoom: CGFloat, panX: CGFloat, panY: CGFloat) -> (rect: CGRect, out: CGSize) {
        let crop = FramingGeometry.cropRect(in: size, ratio: ratio)
        let z = FramingGeometry.clampZoom(zoom)
        let vw = crop.width / z, vh = crop.height / z
        let slackX = (crop.width - vw) / 2, slackY = (crop.height - vh) / 2
        let px = z > 1 ? min(max(panX, -1), 1) : 0, py = z > 1 ? min(max(panY, -1), 1) : 0
        let rect = CGRect(x: crop.midX - vw / 2 + px * slackX, y: crop.midY - vh / 2 + py * slackY, width: vw, height: vh)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        return (rect, CGSize(width: even(crop.width), height: even(crop.height)))
    }
}

/// Applies the output crop and look to the decoded picture before it is encoded for outputs.
/// The output size is fixed from the moment encoding starts until it goes idle, so a recording never
/// sees a resolution change; zoom, pan and the look can still change live.
final class OutputProcessor {
    /// True when something would change the picture on its way out.
    static var isActive: Bool {
        (OutputFramingPrefs.enabled && (OutputFramingPrefs.aspect.ratio != nil || OutputFramingPrefs.zoom > 1))
            || (LookPrefs.applyOutput && !LookPrefs.name.isEmpty)
    }

    private let lock = NSLock()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: (w: Int, h: Int)?
    private var lockedRatio: CGFloat??
    private var lastKey: (id: UInt32, seed: UInt32)?

    func reset() { lock.lock(); lockedRatio = nil; lastKey = nil; lock.unlock() }

    /// nil when the source hasn't changed since the last processed frame.
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard Self.isActive else { return input }
        lock.lock(); defer { lock.unlock() }
        if let s = CVPixelBufferGetIOSurface(input)?.takeUnretainedValue() {
            let key = (id: IOSurfaceGetID(s), seed: IOSurfaceGetSeed(s))
            if let last = lastKey, last == key { return nil }
            lastKey = key
        }
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        let ratio: CGFloat?
        if let locked = lockedRatio { ratio = locked } else {
            ratio = OutputFramingPrefs.enabled ? OutputFramingPrefs.aspect.ratio : nil
            lockedRatio = .some(ratio)
        }
        let framing = OutputFramingPrefs.enabled
        let plan = OutputGeometry.plan(size: CGSize(width: w, height: h), ratio: ratio,
                                       zoom: framing ? OutputFramingPrefs.zoom : 1,
                                       panX: framing ? OutputFramingPrefs.panX : 0, panY: framing ? OutputFramingPrefs.panY : 0)
        let ow = Int(plan.out.width), oh = Int(plan.out.height)
        if poolSize?.w != ow || poolSize?.h != oh { makePool(ow, oh) }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return input }

        var image = CIImage(cvPixelBuffer: input)
        if LookPrefs.applyOutput, let f = LUTLibrary.currentFilter() {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }
        let r = plan.rect
        let sx = plan.out.width / r.width, sy = plan.out.height / r.height
        // Translate first, then scale: p -> sx * (p - minX). (`scaledBy` on a translation would apply the
        // scale first and leave the window off-centre.)
        image = image.transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ci.render(image, to: out, bounds: CGRect(origin: .zero, size: plan.out), colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return out
    }

    private func makePool(_ w: Int, _ h: Int) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p; poolSize = (w, h)
    }
}

// MARK: - Settings

#if canImport(SwiftUI) && canImport(AppKit)
struct LookSettingsSection: View {
    @AppStorage(LookPrefs.nameKey) private var name = ""
    @AppStorage(LookPrefs.intensityKey) private var intensity = 1.0
    @AppStorage(LookPrefs.previewKey) private var preview = true
    @AppStorage(LookPrefs.outputKey) private var output = false
    @State private var names = LUTLibrary.names()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color look (LUT)").font(.headline)
            HStack {
                Picker("Look", selection: $name) {
                    Text("None").tag("")
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                Button("Import .cube…") { importLUT() }
                Button("Remove") { LUTLibrary.remove(name); name = ""; names = LUTLibrary.names() }
                    .disabled(name.isEmpty)
            }
            HStack {
                Text("Intensity").frame(width: 80, alignment: .leading)
                Slider(value: $intensity, in: 0...1).disabled(name.isEmpty)
                Text("\(Int(intensity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Toggle("Apply to the preview", isOn: $preview).disabled(name.isEmpty)
            Toggle("Apply to recordings, replay and streams", isOn: $output).disabled(name.isEmpty)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("Import a 3D .cube look (Rec.709 in, Rec.709 out), e.g. to lift hazy or flat goggles footage. Applying it to outputs re-encodes the picture, like the keyframe encoder does. The preview change shows after the window is next resized or reopened.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = "Reading look…"
        // Large tables take a moment to parse; keep the UI responsive.
        Task.detached {
            let imported = try? LUTLibrary.importFile(url)
            await MainActor.run {
                if let imported { name = imported; names = LUTLibrary.names(); message = nil }
                else { message = "Couldn't read that file as a 3D .cube LUT (max 64 MB, size 2 to 129)." }
            }
        }
    }
}

struct OutputFramingSettingsSection: View {
    @AppStorage(OutputFramingPrefs.enabledKey) private var enabled = false
    @AppStorage(OutputFramingPrefs.aspectKey) private var aspect = FramingAspect.fit.rawValue
    @AppStorage(OutputFramingPrefs.zoomKey) private var zoom = 1.0
    @AppStorage(OutputFramingPrefs.panXKey) private var panX = 0.0
    @AppStorage(OutputFramingPrefs.panYKey) private var panY = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output framing").font(.headline)
            Toggle("Use a separate crop for recordings, replay and streams", isOn: $enabled)
            Picker("Aspect", selection: $aspect) {
                ForEach([FramingAspect.fit, .r16x9, .r4x3, .r1x1, .r9x16]) { Text($0 == .fit ? "Full" : $0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).disabled(!enabled)
            row("Zoom", $zoom, 1...4, format: "%.1fx")
            row("Horizontal", $panX, -1...1, format: "%+.2f")
            row("Vertical", $panY, -1...1, format: "%+.2f")
            Text("Independent of the preview framing above. Aspect is read when encoding starts (stop and restart recording or streams to change it); zoom and position can change live. Output is re-encoded with the keyframe encoder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range).disabled(!enabled || (title != "Zoom" && zoom <= 1))
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}
#endif
