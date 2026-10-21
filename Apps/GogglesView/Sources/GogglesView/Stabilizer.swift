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
/// How the camera motion is measured. `translation` is the original behaviour (no roll correction).
enum StabilizerMode: String, CaseIterable {
    case translation
    case similarityHomography = "similarity-homography"
    /// Never the default: on real footage it was about 14% shakier than no stabilization, with roll errors near 5 degrees (garbage tile fits).
    case similarityTiles = "similarity-tiles"
}

enum StabilizerPrefs {
    static let modeKey = "stabilizeMode"
    /// Real goggles footage (`GogglesView --stab-file`, see StabHarness.swift): tiles was the worst (garbage tile fits, roll
    /// drift), roll correction gave no measurable gain on shaky runs and costs about 2% more zoom (it only helped on near-static
    /// footage), so translation stays the default. It is measured with the homography registration since the translational
    /// request made the picture shakier than the input on real footage.
    static let defaultMode = StabilizerMode.translation
    static var mode: StabilizerMode {
        (UserDefaults.standard.string(forKey: modeKey)).flatMap(StabilizerMode.init(rawValue:)) ?? defaultMode
    }
    static let enabledKey = "stabilizeEnabled"
    static let strengthKey = "stabilizeStrength"
    static let defaultStrength = 0.6

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var strength: Double {
        let v = UserDefaults.standard.object(forKey: strengthKey) as? Double ?? defaultStrength
        return min(max(v, 0), 1)
    }

    /// Most that can be cropped from each edge for the correction (the zoom that hides it): 4% to 10%.
    static func margin(forStrength s: Double) -> Double { 0.04 + 0.06 * min(max(s, 0), 1) }
    /// Crop used while the picture is steady: the zoom only grows when a correction needs the room.
    static let restingMargin = 0.02

    /// The crop to use now: as much as the recent corrections needed (instant attack, slow release via `peak`,
    /// the largest correction seen lately as a fraction of the frame), never above `cap`, never below the resting
    /// crop. Always at least what the current correction needs, so the frame edge is never revealed.
    /// Crop (per edge, as a fraction) a rotation of `roll` radians eats on a `w` x `h` frame, so it can be added to the translation need.
    static func rollMargin(_ roll: Double, w: Double, h: Double) -> Double {
        let a = max(w / h, h / w), r = abs(roll)
        return (1 - 1 / (cos(r) + sin(r) * a)) / 2
    }

    static func effectiveMargin(peak: Double, cap: Double) -> Double {
        min(cap, max(restingMargin, peak + 0.01))
    }
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

/// What the stabilizer did since the last `resetStats()`: for diagnostics and the `--stab-probe` dev flag.
struct StabilizerStats: Equatable {
    var frames = 0
    /// Frames that started a new path because the frame timeline jumped (or the decoder reset).
    var resets = 0
    /// Frames where the motion measurement failed.
    var measureFailures = 0
    /// Frames whose measured motion was implausibly large and was ignored (see `Stabilizer.gate`).
    var outliers = 0
    var sumMotionPx = 0.0       // |motion| per frame, summed
    var sumCorrectionPx = 0.0   // |correction| per frame, summed
    /// Motion measured again on the stabilized output (probe only, see `Stabilizer.probeResidual`).
    var sumResidualPx = 0.0
    var residualFrames = 0
    var meanResidualPx: Double { residualFrames > 0 ? sumResidualPx / Double(residualFrames) : 0 }
    var sumZoom = 0.0
    var meanZoom: Double { frames > 0 ? sumZoom / Double(frames) : 1 }
    var meanMotionPx: Double { frames > 0 ? sumMotionPx / Double(frames) : 0 }
    var meanCorrectionPx: Double { frames > 0 ? sumCorrectionPx / Double(frames) : 0 }
}

/// What is analysed to measure the camera motion. Real goggles footage (see `StabHarness`) showed that the whole frame
/// at 640 px is not the best choice: the central part measures the shake without edge overlays and vignetting, and the
/// registration cost grows with the pixel count.
struct StabilizerTuning: Equatable {
    /// Width (px) the analysed image is scaled to.
    var analysisWidth = 384
    /// Central fraction of the frame that is analysed (1 = whole frame).
    var analysisROI = 0.7
    /// Previous behaviour: translation mode measured with the plain translational registration (cheaper, but shakier on real footage).
    var legacyTranslationRegistration = false
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
    private var _stats = StabilizerStats()
    private var previousOutSmall: CVPixelBuffer?
    /// Largest recent correction as a fraction of the frame (decays slowly), drives the adaptive zoom.
    private var correctionPeak = 0.0
    /// Dev probe: also measure the motion left in the stabilized output (costs a second analysis per frame).
    nonisolated(unsafe) static var probeResidual = false
    /// Dev probe: the raw measured motion of every frame, in order (full-size pixels), for offline tuning.
    private(set) var motionLog: [CGPoint] = []
    func takeMotionLog() -> [CGPoint] { statLock.lock(); defer { statLock.unlock() }; let l = motionLog; motionLog = []; return l }
    /// One context for every feed (a context per feed kept its own Core Image caches, which grew with the feed count).
    private static let sharedContext = CIContext(options: [.cacheIntermediates: false])
    private var ci: CIContext { Self.sharedContext }
    private var smoother = PathSmoother(strength: StabilizerPrefs.defaultStrength)
    /// Roll (radians) rides on the x axis of its own smoother.
    private var rollSmoother = PathSmoother(strength: StabilizerPrefs.defaultStrength)
    private var previousSmall: CVPixelBuffer?
    private var outPool: CVPixelBufferPool?
    private var smallPool: CVPixelBufferPool?
    private var poolKey: (w: Int, h: Int, fmt: OSType, aw: Int)?
    /// Tuning knobs; the dev harness sweeps them on recorded footage. Pools are rebuilt when the width changes.
    var tuning = StabilizerTuning()

    deinit { StabilizerStatus.shared.set(ObjectIdentifier(self), paused: false) }

    /// Smoothed time spent per frame, for diagnostics. Safe to read from any thread.
    var costMs: Double? { statLock.lock(); defer { statLock.unlock() }; return _costMs }

    /// True while stabilization is skipped because it was costing too much of the frame interval.
    var isBypassed: Bool {
        statLock.lock(); defer { statLock.unlock() }
        return budget.isBypassed(atMs: Self.nowMs())
    }

    var stats: StabilizerStats { statLock.lock(); defer { statLock.unlock() }; return _stats }
    func resetStats() { statLock.lock(); _stats = StabilizerStats(); statLock.unlock() }

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
        guard ProgramOutputPrefs.stabilizeActive() || (StabilizerPrefs.enabled && !RaceModePrefs.enabled) else {
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

    /// Drain the autoreleased Core Image / Vision objects after each picture (the decoder's thread does not).
    func process(_ input: CVPixelBuffer, strength: Double, mode: StabilizerMode = StabilizerPrefs.mode) -> CVPixelBuffer {
        autoreleasepool { processUnpooled(input, strength: strength, mode: mode) }
    }

    private func processUnpooled(_ input: CVPixelBuffer, strength: Double, mode: StabilizerMode) -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        statLock.lock()
        let doReset = resetRequested
        resetRequested = false
        statLock.unlock()
        if doReset {
            previousSmall = nil; smoother.reset(); rollSmoother.reset(); correctionPeak = 0
            statLock.lock(); _stats.resets += 1; statLock.unlock()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        guard w > 64, h > 64 else { return input }
        let fmt = CVPixelBufferGetPixelFormatType(input)
        if poolKey?.w != w || poolKey?.h != h || poolKey?.fmt != fmt || poolKey?.aw != tuning.analysisWidth {
            makePools(w: w, h: h, fmt: fmt)
            previousSmall = nil
            smoother.reset(); rollSmoother.reset()
        }
        smoother.strength = strength; rollSmoother.strength = strength
        guard let outPool, let smallPool,
              let small = makeBuffer(from: smallPool),
              let out = makeBuffer(from: outPool) else { return input }

        let roi = CGFloat(min(max(tuning.analysisROI, 0.3), 1))
        let scale = CGFloat(tuning.analysisWidth) / (CGFloat(w) * roi)
        let image = CIImage(cvPixelBuffer: input)
        let crop = CGRect(x: CGFloat(w) * (1 - roi) / 2, y: CGFloat(h) * (1 - roi) / 2, width: CGFloat(w) * roi, height: CGFloat(h) * roi)
        ci.render(image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale))), to: small)

        var motion = CGPoint.zero
        var rollMotion = 0.0
        var measureFailed = false
        var outlier = false
        if let prev = previousSmall {
            if let m = (tuning.legacyTranslationRegistration && mode == .translation ? Stabilizer.measure(from: prev, to: small).map { ($0, 0.0) } : Stabilizer.measure(from: prev, to: small, mode: mode)) {
                let gated = Stabilizer.gate(CGPoint(x: m.t.x / scale, y: m.t.y / scale), width: CGFloat(w))
                motion = gated.motion
                outlier = gated.rejected
                if !outlier, abs(m.roll) <= Self.maxPlausibleRoll { rollMotion = m.roll } else { outlier = true }
            } else { measureFailed = true }
        }
        previousSmall = small

        let capMargin = StabilizerPrefs.margin(forStrength: strength)
        // With roll on, translation and rotation share the crop budget (65% / 35%), so their sum never exceeds the cap.
        let similarity = mode != .translation
        let tShare = similarity ? 0.65 : 1.0
        let c = smoother.step(motion: motion, limit: CGSize(width: CGFloat(capMargin * tShare) * CGFloat(w), height: CGFloat(capMargin * tShare) * CGFloat(h)))
        var rollC = 0.0
        if similarity {
            let rl = CGFloat(0.7 * capMargin / max(Double(w) / Double(h), Double(h) / Double(w)))
            rollC = Double(rollSmoother.step(motion: CGPoint(x: rollMotion, y: 0), limit: CGSize(width: rl, height: rl)).x)
        }
        let need = max(Double(abs(c.x)) / Double(w), Double(abs(c.y)) / Double(h)) + StabilizerPrefs.rollMargin(rollC, w: Double(w), h: Double(h))
        correctionPeak = max(need, correctionPeak * 0.995)
        let margin = CGFloat(StabilizerPrefs.effectiveMargin(peak: correctionPeak, cap: capMargin))
        statLock.lock()
        if Self.probeResidual { motionLog.append(motion) }
        _stats.frames += 1
        if measureFailed { _stats.measureFailures += 1 }
        if outlier { _stats.outliers += 1 }
        _stats.sumMotionPx += Double(hypot(motion.x, motion.y))
        _stats.sumCorrectionPx += Double(hypot(c.x, c.y))
        _stats.sumZoom += Double(1 / (1 - 2 * margin))
        statLock.unlock()
        let zoom = 1 / (1 - 2 * margin)
        let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rollC)))
            .concatenating(CGAffineTransform(translationX: cx + c.x, y: cy + c.y))
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        ci.render(image.transformed(by: t), to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709))
        copyAttachments(from: input, to: out)
        if Self.probeResidual, let probeSmall = makeBuffer(from: smallPool) {
            let probeScale = CGFloat(tuning.analysisWidth) / CGFloat(w)
            ci.render(CIImage(cvPixelBuffer: out).transformed(by: CGAffineTransform(scaleX: probeScale, y: probeScale)), to: probeSmall)
            if let prevOut = previousOutSmall, let r = Stabilizer.measure(from: prevOut, to: probeSmall) {
                statLock.lock()
                _stats.sumResidualPx += Double(hypot(r.x / probeScale, r.y / probeScale)); _stats.residualFrames += 1
                statLock.unlock()
            }
            previousOutSmall = probeSmall
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        statLock.lock()
        _costMs = _costMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
        budget.record(costMs: ms, intervalMs: clockWatch.intervalMs, atMs: Self.nowMs())
        statLock.unlock()
        return out
    }

    /// Largest believable motion between two frames, as a fraction of the frame width. Hard shake measures up to
    /// about 10%; motion-blurred frames make the registration lock onto garbage and report 30 to 80% of the width in
    /// a random direction. Those jumped the whole camera path and the correction slammed into its limit, so strong
    /// shake came out worse than it went in. Tuned on 670 frames of real footage: gating cut the remaining shake by
    /// about 80% at full strength, against about 33% without.
    static let maxPlausibleMotion = 0.25

    /// Largest believable roll between two frames (radians, about 8.6 degrees).
    static let maxPlausibleRoll = 0.15

    /// Returns `motion`, or zero when it is implausibly large for a frame `width` pixels wide.
    static func gate(_ motion: CGPoint, width: CGFloat) -> (motion: CGPoint, rejected: Bool) {
        hypot(motion.x, motion.y) > maxPlausibleMotion * width ? (.zero, true) : (motion, false)
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

    /// Content motion between two frames for `mode`: translation of the frame centre plus roll (radians, counter-clockwise, y up).
    static func measure(from: CVPixelBuffer, to: CVPixelBuffer, mode: StabilizerMode) -> (t: CGPoint, roll: Double)? {
        switch mode {
        // Translation only, but measured with the homography registration: on real footage the translational request
        // returned garbage jumps and made the picture shakier than the input, the homography one did not.
        case .translation: return measureHomography(from: from, to: to).map { ($0.t, 0) }
        case .similarityHomography: return measureHomography(from: from, to: to)
        case .similarityTiles: return measureTiles(from: from, to: to)
        }
    }

    private static func measureHomography(from: CVPixelBuffer, to: CVPixelBuffer) -> (t: CGPoint, roll: Double)? {
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: to)
        let handler = VNImageRequestHandler(cvPixelBuffer: from, options: [:])
        guard (try? handler.perform([request])) != nil,
              let r = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        // warpTransform aligns `to` onto `from`; its inverse is the content motion. Small-angle: scale and perspective are ignored.
        let a = r.warpTransform.inverse
        let c = SIMD3<Float>(Float(CVPixelBufferGetWidth(to)) / 2, Float(CVPixelBufferGetHeight(to)) / 2, 1)
        let q = a * c
        guard q.z.isFinite, abs(q.z) > 1e-6 else { return nil }
        return (CGPoint(x: CGFloat(q.x / q.z - c.x), y: CGFloat(q.y / q.z - c.y)), Double(atan2(a[0][1], a[0][0])))
    }

    /// 3x3 grid of translational registrations, least-squares similarity fit, tiles far from the fit dropped and refit.
    private static func measureTiles(from: CVPixelBuffer, to: CVPixelBuffer) -> (t: CGPoint, roll: Double)? {
        let pw = CVPixelBufferGetWidth(to), ph = CVPixelBufferGetHeight(to)
        let w = Double(pw), h = Double(ph), tw = pw / 3, th = ph / 3
        guard CVPixelBufferGetPixelFormatType(to) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(from) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(from, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(from, .readOnly) }
        guard CVPixelBufferLockBaseAddress(to, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(to, .readOnly) }
        // Zero-copy views onto each tile (Vision's regionOfInterest does not restrict registration).
        func tile(_ b: CVPixelBuffer, _ i: Int, _ j: Int) -> CVPixelBuffer? {
            let bpr = CVPixelBufferGetBytesPerRow(b)
            let base = CVPixelBufferGetBaseAddress(b)! + (ph - (j + 1) * th) * bpr + i * tw * 4
            var t: CVPixelBuffer?
            CVPixelBufferCreateWithBytes(nil, tw, th, kCVPixelFormatType_32BGRA, base, bpr, nil, nil, nil, &t)
            return t
        }
        // Vision request creation is not thread-safe (crashes in VNSession).
        var jobs: [(i: Int, j: Int, req: VNTranslationalImageRegistrationRequest, handler: VNImageRequestHandler)] = []
        for k in 0..<9 {
            let i = k % 3, j = k / 3
            guard let tf = tile(from, i, j), let tt = tile(to, i, j) else { continue }
            jobs.append((i, j, VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: tt), VNImageRequestHandler(cvPixelBuffer: tf, options: [:])))
        }
        // Performed serially: concurrent perform() calls raced inside VisionCore (NSRangeException in its weak-object
        // collection, after about 1000 frames of real footage).
        var slots = [(r: SIMD2<Double>, d: SIMD2<Double>)?](repeating: nil, count: jobs.count)
        for k in 0..<jobs.count {
            let (i, j, req, handler) = jobs[k]
            guard (try? handler.perform([req])) != nil,
                  let o = req.results?.first as? VNImageTranslationAlignmentObservation else { continue }
            slots[k] = (r: SIMD2((Double(i) + 0.5) / 3 * w - w / 2, (Double(j) + 0.5) / 3 * h - h / 2),
                        d: SIMD2(-o.alignmentTransform.tx, -o.alignmentTransform.ty))
        }
        let samples = slots.compactMap { $0 }
        func fit(_ s: [(r: SIMD2<Double>, d: SIMD2<Double>)]) -> (t: SIMD2<Double>, roll: Double) {
            let n = Double(s.count)
            let rb = s.reduce(SIMD2<Double>.zero) { $0 + $1.r } / n, db = s.reduce(SIMD2<Double>.zero) { $0 + $1.d } / n
            var num = 0.0, den = 0.0
            for e in s { let r = e.r - rb, d = e.d - db; num += r.x * d.y - r.y * d.x; den += r.x * r.x + r.y * r.y }
            let th = den > 0 ? num / den : 0
            return (db - th * SIMD2(-rb.y, rb.x), th)
        }
        func residual(_ f: (t: SIMD2<Double>, roll: Double), _ e: (r: SIMD2<Double>, d: SIMD2<Double>)) -> Double {
            let p = f.t + f.roll * SIMD2(-e.r.y, e.r.x)
            return (e.d - p).x * (e.d - p).x + (e.d - p).y * (e.d - p).y
        }
        guard samples.count >= 5 else { return nil }
        var f = fit(samples)
        let res = samples.map { residual(f, $0).squareRoot() }
        let median = res.sorted()[res.count / 2]
        // Drop tiles more than 2.5x the median residual (and at least 1 px) off the fit: moving foreground, blur.
        let kept = zip(samples, res).filter { $0.1 <= max(1.0, 2.5 * median) }.map { $0.0 }
        if kept.count >= 4, kept.count < samples.count { f = fit(kept) }
        return (CGPoint(x: f.t.x, y: f.t.y), f.roll)
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
        let sw = tuning.analysisWidth, sh = max(2, Int((Double(h) / Double(w) * Double(sw)).rounded()))
        outPool = pool(w, h, fmt)
        smallPool = pool(sw, sh, kCVPixelFormatType_32BGRA)
        poolKey = (w, h, fmt, tuning.analysisWidth)
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
    @AppStorage(StabilizerPrefs.modeKey) private var mode = StabilizerPrefs.defaultMode.rawValue
    @ObservedObject private var status = StabilizerStatus.shared

    var body: some View {
        SettingsGroup("Live stabilization") {
            SettingsToggleRow("Stabilize the live picture", isOn: $enabled,
                info: "Smooths shaky footage. Zooms in slightly (4 to 10%) to hide the edges and adds a tiny delay (a few ms). Applies to the preview, recordings and streams.")
            SettingsSliderRow("Strength", value: $strength, range: 0...1, scale: 100, unit: "%", indented: true)
                .disabled(!enabled)
            SettingsRow("Stabilization mode", indented: true) {
                Picker("Stabilization mode", selection: $mode) {
                    Text("Translation only").tag(StabilizerMode.translation.rawValue)
                    Text("Translation and roll (homography)").tag(StabilizerMode.similarityHomography.rawValue)
                    Text("Translation and roll (tiles)").tag(StabilizerMode.similarityTiles.rawValue)
                }.labelsHidden().disabled(!enabled)
            }
            if status.paused {
                SettingsRow("Status") {
                    Text("Stabilization is paused because this Mac can't keep up with the frame rate. It tries again every few seconds.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
