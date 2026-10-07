import Foundation
import CoreImage
import CoreVideo
import Vision
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Live electronic stabilization of the decoded picture.
///
/// Causal by design: each frame is corrected using only the motion seen so far (no look-ahead
/// buffer), so it adds processing time (a few ms) but no frames of delay. It removes shake, not
/// slow pans, by low-pass filtering the cumulative camera path and shifting the frame by the
/// difference. A small zoom hides the edges the shift would otherwise reveal.
enum StabilizerPrefs {
    static let enabledKey = "stabilizeEnabled"
    static let strengthKey = "stabilizeStrength"
    static let defaultStrength = 0.6

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var strength: Double {
        let v = UserDefaults.standard.object(forKey: strengthKey) as? Double ?? defaultStrength
        return min(max(v, 0), 1)
    }

    /// Fraction of each edge reserved for the correction (the zoom that hides it): 4% to 10%.
    static func margin(forStrength s: Double) -> Double { 0.04 + 0.06 * min(max(s, 0), 1) }
}

/// Low-pass filter of the cumulative camera path. Pure math, no images.
struct PathSmoother {
    var strength: Double
    private(set) var path = CGPoint.zero
    private(set) var smooth = CGPoint.zero

    init(strength: Double) { self.strength = strength }

    /// `motion` is how far the picture content moved since the previous frame; `limit` is the
    /// largest correction that can be shown without revealing the frame edge. Returns the shift to
    /// apply to the current frame so its content sits where the smoothed path says it should.
    mutating func step(motion: CGPoint, limit: CGSize) -> CGPoint {
        path.x += motion.x; path.y += motion.y
        let alpha = CGFloat(0.5 + 0.48 * min(max(strength, 0), 1))
        smooth.x = alpha * smooth.x + (1 - alpha) * path.x
        smooth.y = alpha * smooth.y + (1 - alpha) * path.y
        var c = CGPoint(x: smooth.x - path.x, y: smooth.y - path.y)
        // Past the limit the smoothed path is dragged along so the picture follows a real pan.
        if abs(c.x) > limit.width { c.x = c.x < 0 ? -limit.width : limit.width; smooth.x = path.x + c.x }
        if abs(c.y) > limit.height { c.y = c.y < 0 ? -limit.height : limit.height; smooth.y = path.y + c.y }
        return c
    }

    mutating func reset() { path = .zero; smooth = .zero }
}

/// Spots a break in the frame timeline (the clock went backwards, or frames stopped for a while),
/// where the previous frame is no longer a valid reference for motion measurement. Also keeps a
/// smoothed frame interval so the cost budget knows the real frame rate.
struct FrameClockWatch {
    static let maxGapNs: Int64 = 1_000_000_000
    private var last: Int64?
    private(set) var intervalMs: Double?

    /// Feeds one timestamp (nanoseconds). Returns true when the timeline jumped.
    mutating func note(_ ns: Int64) -> Bool {
        defer { last = ns }
        guard let last else { return false }
        let delta = ns - last
        if delta <= 0 || delta > Self.maxGapNs { return true }
        let ms = Double(delta) / 1_000_000
        // Ignore implausible intervals when estimating the rate (bursts, short stalls).
        if ms >= 4, ms <= 200 { intervalMs = intervalMs.map { $0 * 0.9 + ms * 0.1 } ?? ms }
        return false
    }
}

/// Stops stabilizing when it costs too much of the frame interval, so decoded frames do not queue
/// behind it. Hysteresis: once over budget it stays off for a growing pause, then tries again.
struct StabilizerBudget {
    static let defaultIntervalMs = 1000.0 / 60.0
    static let limitFraction = 0.8
    static let minSamples = 5
    static let firstPauseMs = 2_000.0
    static let maxPauseMs = 16_000.0

    private(set) var smoothedMs: Double?
    private(set) var bypassUntilMs: Double?
    private var samples = 0
    private var goodSamples = 0
    private var pauseMs = StabilizerBudget.firstPauseMs

    /// True while stabilization is switched off for exceeding the budget.
    func isBypassed(atMs nowMs: Double) -> Bool {
        guard let until = bypassUntilMs else { return false }
        return nowMs < until
    }

    /// Records the cost of one stabilized frame. `intervalMs` is the real frame interval when known.
    mutating func record(costMs: Double, intervalMs: Double?, atMs nowMs: Double) {
        let interval = intervalMs ?? Self.defaultIntervalMs
        smoothedMs = smoothedMs.map { $0 * 0.9 + costMs * 0.1 } ?? costMs
        samples += 1
        guard samples >= Self.minSamples, let smoothed = smoothedMs else { return }
        if smoothed > interval * Self.limitFraction {
            bypassUntilMs = nowMs + pauseMs
            pauseMs = min(pauseMs * 2, Self.maxPauseMs)
            smoothedMs = nil; samples = 0; goodSamples = 0
        } else {
            goodSamples += 1
            if goodSamples >= 60 { pauseMs = Self.firstPauseMs }
        }
    }
}

/// Lets the Settings screen say that stabilization is paused (any open window).
final class StabilizerStatus: ObservableObject {
    static let shared = StabilizerStatus()
    @Published private(set) var paused = false
    private var pausedIds = Set<ObjectIdentifier>()

    func set(_ id: ObjectIdentifier, paused isPaused: Bool) {
        DispatchQueue.main.async {
            if isPaused { self.pausedIds.insert(id) } else { self.pausedIds.remove(id) }
            let now = !self.pausedIds.isEmpty
            if now != self.paused { self.paused = now }
        }
    }
}

final class Stabilizer {
    private let lock = NSLock()
    /// Guards the small cross-thread state below, so readers never wait for a frame to finish.
    private let statLock = NSLock()
    private var _costMs: Double?
    private var budget = StabilizerBudget()
    private var clockWatch = FrameClockWatch()
    private var resetRequested = false
    private var reportedBypass = false
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var smoother = PathSmoother(strength: StabilizerPrefs.defaultStrength)
    private var previousSmall: CVPixelBuffer?
    private var outPool: CVPixelBufferPool?
    private var smallPool: CVPixelBufferPool?
    private var poolKey: (w: Int, h: Int, fmt: OSType)?
    private static let analysisWidth = 640

    deinit { StabilizerStatus.shared.set(ObjectIdentifier(self), paused: false) }

    /// Smoothed time spent per frame, for diagnostics. Safe to read from any thread.
    var costMs: Double? { statLock.lock(); defer { statLock.unlock() }; return _costMs }

    /// True while stabilization is skipped because it was costing too much of the frame interval.
    var isBypassed: Bool {
        statLock.lock(); defer { statLock.unlock() }
        return budget.isBypassed(atMs: Self.nowMs())
    }

    private static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    /// Forget the previous frame and the camera path: the next frame starts a new session
    /// (decoder reset, reconnect, timestamp jump). Safe to call from any thread.
    func reset() {
        statLock.lock(); resetRequested = true; statLock.unlock()
    }

    /// Feeds the frame's timestamp (nanoseconds); a jump in the timeline resets the path.
    func noteTimestamp(_ ns: Int64) {
        statLock.lock()
        if clockWatch.note(ns) { resetRequested = true }
        statLock.unlock()
    }

    /// Returns a stabilized copy of `input`, or `input` itself when off or when anything fails.
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer {
        guard StabilizerPrefs.enabled, !RaceModePrefs.enabled else {
            lock.lock(); if previousSmall != nil { previousSmall = nil; smoother.reset() }; lock.unlock()
            publishBypass(false)
            return input
        }
        statLock.lock()
        let bypass = budget.isBypassed(atMs: Self.nowMs())
        if bypass { resetRequested = true }
        statLock.unlock()
        publishBypass(bypass)
        if bypass { return input }
        return process(input, strength: StabilizerPrefs.strength)
    }

    private func publishBypass(_ on: Bool) {
        statLock.lock()
        let changed = reportedBypass != on
        reportedBypass = on
        statLock.unlock()
        if changed { StabilizerStatus.shared.set(ObjectIdentifier(self), paused: on) }
    }

    func process(_ input: CVPixelBuffer, strength: Double) -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        statLock.lock()
        let doReset = resetRequested
        resetRequested = false
        statLock.unlock()
        if doReset { previousSmall = nil; smoother.reset() }
        let start = DispatchTime.now().uptimeNanoseconds
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        guard w > 64, h > 64 else { return input }
        let fmt = CVPixelBufferGetPixelFormatType(input)
        if poolKey?.w != w || poolKey?.h != h || poolKey?.fmt != fmt {
            makePools(w: w, h: h, fmt: fmt)
            previousSmall = nil
            smoother.reset()
        }
        smoother.strength = strength
        guard let outPool, let smallPool,
              let small = makeBuffer(from: smallPool),
              let out = makeBuffer(from: outPool) else { return input }

        let scale = CGFloat(Self.analysisWidth) / CGFloat(w)
        let image = CIImage(cvPixelBuffer: input)
        ci.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: small)

        var motion = CGPoint.zero
        if let prev = previousSmall, let m = Stabilizer.measure(from: prev, to: small) {
            motion = CGPoint(x: m.x / scale, y: m.y / scale)
        }
        previousSmall = small

        let margin = CGFloat(StabilizerPrefs.margin(forStrength: strength))
        let c = smoother.step(motion: motion, limit: CGSize(width: margin * CGFloat(w), height: margin * CGFloat(h)))
        let zoom = 1 / (1 - 2 * margin)
        let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        ci.render(image.transformed(by: t), to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709))
        copyAttachments(from: input, to: out)

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        statLock.lock()
        _costMs = _costMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
        budget.record(costMs: ms, intervalMs: clockWatch.intervalMs, atMs: Self.nowMs())
        statLock.unlock()
        return out
    }

    /// How far the content of `to` moved relative to `from`, in pixels of those buffers (y up).
    static func measure(from: CVPixelBuffer, to: CVPixelBuffer) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: to)
        let handler = VNImageRequestHandler(cvPixelBuffer: from, options: [:])
        guard (try? handler.perform([request])) != nil,
              let r = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        // The transform aligns `to` back onto `from`, i.e. it is the opposite of the content motion.
        return CGPoint(x: -r.alignmentTransform.tx, y: -r.alignmentTransform.ty)
    }

    private func makePools(w: Int, h: Int, fmt: OSType) {
        func pool(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBufferPool? {
            var p: CVPixelBufferPool?
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: fmt,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            return p
        }
        let sw = Self.analysisWidth, sh = max(2, Int((Double(h) / Double(w) * Double(sw)).rounded()))
        outPool = pool(w, h, fmt)
        smallPool = pool(sw, sh, kCVPixelFormatType_32BGRA)
        poolKey = (w, h, fmt)
    }

    private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) == kCVReturnSuccess else { return nil }
        return b
    }

    private func copyAttachments(from a: CVPixelBuffer, to b: CVPixelBuffer) {
        if let atts = CVBufferCopyAttachments(a, .shouldPropagate) {
            CVBufferSetAttachments(b, atts, .shouldPropagate)
        }
    }
}

#if canImport(SwiftUI)
struct StabilizerSettingsSection: View {
    @AppStorage(StabilizerPrefs.enabledKey) private var enabled = false
    @AppStorage(StabilizerPrefs.strengthKey) private var strength = StabilizerPrefs.defaultStrength
    @ObservedObject private var status = StabilizerStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live stabilization").font(.headline)
            Toggle("Stabilize the live picture", isOn: $enabled)
            HStack {
                Text("Strength")
                Slider(value: $strength, in: 0...1).disabled(!enabled)
                Text("\(Int(strength * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            if status.paused {
                Text("Stabilization is paused because this Mac can't keep up with the frame rate. It tries again every few seconds.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Smooths shaky footage. Zooms in slightly (4 to 10%) to hide the edges and adds a tiny delay (a few ms). Applies to the preview, recordings and streams.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
