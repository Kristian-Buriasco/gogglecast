import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Vision

/// Pure metrics for judging stabilizer output: how much a motion path wobbles around its own smooth version.
enum StabMetrics {
    /// Smoothing sigma (frames) separating "shake" from intended motion: 5 frames is a ~1.2 Hz corner at 35 fps.
    nonisolated(unsafe) static var sigma = 5.0
    /// Gaussian smoothing with mirrored edges.
    static func gaussianSmooth(_ x: [Double], sigma: Double) -> [Double] {
        guard x.count > 1, sigma > 0 else { return x }
        let r = Int((3 * sigma).rounded(.up))
        let k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let ks = k.reduce(0, +)
        let n = x.count
        func at(_ i: Int) -> Double {
            var j = i
            while j < 0 || j >= n { j = j < 0 ? -j : 2 * (n - 1) - j; if n == 1 { return x[0] } }
            return x[j]
        }
        return (0..<n).map { i in (-r...r).reduce(0.0) { $0 + k[$1 + r] * at(i + $1) } / ks }
    }

    static func cumulative(_ d: [Double]) -> [Double] {
        var s = 0.0
        return d.map { s += $0; return s }
    }

    /// RMS of `path - gaussianSmooth(path)`: the shake left on a camera path, in the path's own unit.
    static func highpassRMS(path: [Double], sigma: Double = StabMetrics.sigma) -> Double {
        guard path.count > 2 else { return 0 }
        let s = gaussianSmooth(path, sigma: sigma)
        return (zip(path, s).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(path.count)).squareRoot()
    }

    /// Mean |path - gaussian(path, sigma)| over a 2D path, the definition the offline ffmpeg/OpenCV study uses (sigma 8 there).
    static func meanNormHP(dx: [Double], dy: [Double], sigma: Double = 8) -> Double {
        let px = cumulative(dx), py = cumulative(dy), sx = gaussianSmooth(px, sigma: sigma), sy = gaussianSmooth(py, sigma: sigma)
        return (0..<px.count).reduce(0.0) { $0 + hypot(px[$1] - sx[$1], py[$1] - sy[$1]) } / Double(max(1, px.count))
    }

    /// Shake of a 2D path (per-frame motions): sqrt(hx^2 + hy^2) combined.
    static func highpassRMS2D(dx: [Double], dy: [Double], sigma: Double = StabMetrics.sigma) -> Double {
        let a = highpassRMS(path: cumulative(dx), sigma: sigma), b = highpassRMS(path: cumulative(dy), sigma: sigma)
        return (a * a + b * b).squareRoot()
    }
}

/// Dev harness: real recorded footage through the live `Stabilizer` and the offline measurements around it.
enum StabHarness {
    static let ci = CIContext(options: [.cacheIntermediates: false])

    static func makeBuffer(_ w: Int, _ h: Int, _ fmt: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, fmt, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &b)
        return b!
    }

    /// Decodes `seconds` of `url` from `start` as 420v and calls `body(frame, ptsNs)`; return false to stop.
    static func decode(_ url: URL, start: Double, seconds: Double, body: (CVPixelBuffer, Int64) -> Bool) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { print("cannot open \(url.path)"); return }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        reader.add(out)
        guard reader.startReading() else { print("cannot read: \(String(describing: reader.error))"); return }
        while let sb = out.copyNextSampleBuffer() {
            let go: Bool = autoreleasepool {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { return true }
                let ns = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e9)
                return body(pb, ns)
            }
            if !go { break }
        }
        reader.cancelReading()
    }

    /// Synthetic DJI-style OSD: text lines top and bottom, battery box, crosshair, corner brackets (static, on every frame).
    static func osdOverlay(w: Int, h: Int) -> CIImage {
        let W = Double(w), H = Double(h)
        var img = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double) {
            img = CIImage(color: .white).cropped(to: CGRect(x: x, y: y, width: rw, height: rh)).composited(over: img)
        }
        if let f = CIFilter(name: "CITextImageGenerator", parameters: ["inputText": "BAT 16.2V  RSSI 98  00:42  1080p60  2.4G",
                                                                       "inputFontName": "Menlo-Bold", "inputFontSize": 44, "inputScaleFactor": 1.0]),
           let t = f.outputImage {
            let white = t.applyingFilter("CIColorInvert").applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            img = t.transformed(by: CGAffineTransform(translationX: 40, y: H - 90)).composited(over: img)
            img = t.transformed(by: CGAffineTransform(translationX: 40, y: 40)).composited(over: img)
            _ = white
        }
        rect(W - 220, H - 80, 160, 40); rect(W - 58, H - 70, 12, 20)       // battery
        rect(W / 2 - 40, H / 2 - 1, 80, 3); rect(W / 2 - 1, H / 2 - 40, 3, 80) // crosshair
        for (cx, cy) in [(30.0, 30.0), (W - 130, 30), (30, H - 130), (W - 130, H - 130)] { rect(cx, cy, 100, 4); rect(cx, cy, 4, 100) }
        return img
    }

    /// Crop the central `roi` fraction of `input`, scale it to `width`, render BGRA (the recipe the live stabilizer uses for analysis).
    static func analysisBuffer(_ input: CVPixelBuffer, roi: Double, width: Int, overlay: CIImage? = nil) -> CVPixelBuffer {
        let w = Double(CVPixelBufferGetWidth(input)), h = Double(CVPixelBufferGetHeight(input))
        var img = CIImage(cvPixelBuffer: input)
        if let overlay { img = overlay.composited(over: img) }
        let crop = CGRect(x: (w - w * roi) / 2, y: (h - h * roi) / 2, width: w * roi, height: h * roi)
        let s = Double(width) / crop.width
        img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: s, y: s)))
        let b = makeBuffer(width, Int((crop.height * s).rounded()))
        ci.render(img, to: b)
        return b
    }

    struct Meas { var x = 0.0, y = 0.0, r = 0.0, ok = true }

    /// Reference measurement used for every in/out comparison: homography on the central 70% at 960 px.
    static let refRoi = 0.7, refWidth = 960

    static func measure(_ a: CVPixelBuffer, _ b: CVPixelBuffer, mode: StabilizerMode, scale: Double) -> Meas {
        guard let m = Stabilizer.measure(from: a, to: b, mode: mode) else { return Meas(ok: false) }
        return Meas(x: Double(m.t.x) / scale, y: Double(m.t.y) / scale, r: m.roll)
    }

    // MARK: study: raw estimator output for a grid of analysis configs, plus the reference, dumped to CSV

    struct Cfg { var mode: StabilizerMode; var roi: Double; var width: Int; var osd = false
        var key: String { "\(mode.rawValue)|\(roi)|\(width)|\(osd ? "osd" : "clean")" } }

    static func study(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-study") else { return }
        let start = Double(opt("--start") ?? "0") ?? 0, secs = Double(opt("--seconds") ?? "30") ?? 30
        let csv = opt("--csv")
        var cfgs: [Cfg] = []
        if ProcessInfo.processInfo.environment["STAB_CFGS"] == "low" {
            cfgs = [(0.7, 640), (0.7, 480), (0.7, 384), (0.7, 320), (0.5, 384), (0.85, 384)].map { Cfg(mode: .similarityHomography, roi: $0.0, width: $0.1) }
        } else if ProcessInfo.processInfo.environment["STAB_CFGS"] == "min" {
            cfgs = [Cfg(mode: .translation, roi: 1, width: 640), Cfg(mode: .translation, roi: 1, width: 960), Cfg(mode: .translation, roi: 0.7, width: 640),
                    Cfg(mode: .similarityHomography, roi: 0.7, width: 640), Cfg(mode: .similarityHomography, roi: 0.7, width: 480),
                    Cfg(mode: .similarityHomography, roi: 1, width: 640), Cfg(mode: .similarityHomography, roi: 1, width: 480), Cfg(mode: .similarityTiles, roi: 0.7, width: 640)]
        } else {
        for m in StabilizerMode.allCases { cfgs.append(Cfg(mode: m, roi: 1, width: 640)) }
        for m in StabilizerMode.allCases { for (r, wd) in [(1.0, 480), (1.0, 960), (0.7, 640), (0.7, 480), (0.5, 640)] { cfgs.append(Cfg(mode: m, roi: r, width: wd)) } }
        for m in StabilizerMode.allCases { cfgs.append(Cfg(mode: m, roi: 1, width: 640, osd: true)); cfgs.append(Cfg(mode: m, roi: 0.7, width: 640, osd: true)) }
        }
        let ref = Cfg(mode: .similarityHomography, roi: refRoi, width: refWidth)
        var series: [String: [Meas]] = [:], times: [String: Double] = [:]
        var prev: [String: CVPixelBuffer] = [:]
        var overlay: CIImage?
        var n = 0
        decode(URL(fileURLWithPath: file), start: start, seconds: secs) { pb, _ in
            if overlay == nil { overlay = osdOverlay(w: CVPixelBufferGetWidth(pb), h: CVPixelBufferGetHeight(pb)) }
            var bufs: [String: CVPixelBuffer] = [:]
            for c in cfgs + [ref] {
                let k = "\(c.roi)|\(c.width)|\(c.osd)"
                if bufs[k] == nil { bufs[k] = analysisBuffer(pb, roi: c.roi, width: c.width, overlay: c.osd ? overlay : nil) }
            }
            ci.clearCaches()
            for c in cfgs + [ref] {
                let k = "\(c.roi)|\(c.width)|\(c.osd)", cur = bufs[k]!
                let pk = c.key
                if let p = prev[pk] {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let s = Double(c.width) / (Double(CVPixelBufferGetWidth(pb)) * c.roi)
                    series[pk, default: []].append(measure(p, cur, mode: c.mode, scale: s))
                    times[pk, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                }
            }
            for c in cfgs + [ref] { prev[c.key] = bufs["\(c.roi)|\(c.width)|\(c.osd)"] }
            n += 1
            return true
        }
        print("[study] \(file) start=\(start) frames=\(n)")
        for c in cfgs + [ref] {
            let s = series[c.key] ?? []
            print(String(format: "[study] %@ ms/pair=%.2f fail=%d", c.key, (times[c.key] ?? 0) / Double(max(1, s.count)), s.filter { !$0.ok }.count))
        }
        if let csv {
            let keys = (cfgs + [ref]).map { $0.key }
            var out = keys.map { "\($0)#x,\($0)#y,\($0)#r" }.joined(separator: ",") + "\n"
            let rows = series[ref.key]?.count ?? 0
            for i in 0..<rows { out += keys.map { k in let m = series[k]![i]; return String(format: "%.4f,%.4f,%.6f", m.x, m.y, m.r) }.joined(separator: ",") + "\n" }
            try? out.write(toFile: csv, atomically: true, encoding: .utf8)
            print("[study] wrote \(csv)")
        }
    }

    // MARK: independent reference: dense optical flow, robust similarity fit (shares no code with the registration modes)

    /// Content motion between `a` and `b` (y up, px of the buffers, roll in radians CCW) from Vision optical flow.
    static func flowMeasure(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Meas {
        let req = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b, options: [:])
        req.computationAccuracy = .medium
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: a, options: [:])
        guard (try? handler.perform([req])) != nil, let fb = (req.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return Meas(ok: false) }
        CVPixelBufferLockBaseAddress(fb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(fb, .readOnly) }
        let fw = CVPixelBufferGetWidth(fb), fh = CVPixelBufferGetHeight(fb), bpr = CVPixelBufferGetBytesPerRow(fb)
        let base = CVPixelBufferGetBaseAddress(fb)!; if ProcessInfo.processInfo.environment["FLOWDBG"] != nil { print("[flow] buffer \(fw)x\(fh) bpr \(bpr) in \(CVPixelBufferGetWidth(a))x\(CVPixelBufferGetHeight(a))") }
        var pts: [(r: SIMD2<Double>, d: SIMD2<Double>)] = []
        for y in stride(from: 4, to: fh, by: 8) {
            let row = (base + y * bpr).assumingMemoryBound(to: Float.self)
            for x in stride(from: 4, to: fw, by: 8) {
                // Image rows run down; the stabilizer's convention is y up.
                pts.append((SIMD2(Double(x) - Double(fw) / 2, Double(fh) / 2 - Double(y)), SIMD2(Double(row[2 * x]), -Double(row[2 * x + 1]))))
            }
        }
        func fit(_ s: [(r: SIMD2<Double>, d: SIMD2<Double>)]) -> (t: SIMD2<Double>, roll: Double) {
            let n = Double(s.count)
            let rb = s.reduce(SIMD2<Double>.zero) { $0 + $1.r } / n, db = s.reduce(SIMD2<Double>.zero) { $0 + $1.d } / n
            var num = 0.0, den = 0.0
            for e in s { let r = e.r - rb, d = e.d - db; num += r.x * d.y - r.y * d.x; den += r.x * r.x + r.y * r.y }
            let th = den > 0 ? num / den : 0
            return (db - th * SIMD2(-rb.y, rb.x), th)
        }
        func res(_ f: (t: SIMD2<Double>, roll: Double), _ e: (r: SIMD2<Double>, d: SIMD2<Double>)) -> Double {
            let q = e.d - (f.t + f.roll * SIMD2(-e.r.y, e.r.x)); return (q.x * q.x + q.y * q.y).squareRoot()
        }
        guard pts.count > 20 else { return Meas(ok: false) }
        var f = fit(pts)
        for _ in 0..<2 {   // keep the best 60% of points, refit (drops moving foreground)
            let sorted = pts.sorted { res(f, $0) < res(f, $1) }
            f = fit(Array(sorted.prefix(Int(Double(sorted.count) * 0.6))))
        }
        return Meas(x: f.t.x, y: f.t.y, r: f.roll)
    }

    /// `--stab-ref file --start --seconds --csv`: only the flow reference series, aligned frame for frame with `--stab-study`.
    static func refStudy(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-ref"), let csv = opt("--csv") else { return }
        var prev: CVPixelBuffer?
        var rows: [Meas] = []
        decode(URL(fileURLWithPath: file), start: Double(opt("--start") ?? "0") ?? 0, seconds: Double(opt("--seconds") ?? "30") ?? 30) { pb, _ in
            let b = analysisBuffer(pb, roi: 1, width: 640)
            ci.clearCaches()
            if let p = prev { let s = 640.0 / Double(CVPixelBufferGetWidth(pb)); var m = flowMeasure(p, b); m.x /= s; m.y /= s; rows.append(m) }
            prev = b
            return true
        }
        var out = "flow|1.0|640|clean#x,flow|1.0|640|clean#y,flow|1.0|640|clean#r\n"
        for m in rows { out += String(format: "%.4f,%.4f,%.6f\n", m.x, m.y, m.r) }
        try? out.write(toFile: csv, atomically: true, encoding: .utf8)
        print("[ref] \(rows.count) pairs, \(rows.filter { !$0.ok }.count) failed -> \(csv)")
    }

    /// `--stab-selftest file --start t`: a real frame shifted/rolled by known amounts, measured by every estimator and the flow reference.
    static func selfTest(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-selftest") else { return }
        var frame: CVPixelBuffer?
        decode(URL(fileURLWithPath: file), start: Double(opt("--start") ?? "0") ?? 0, seconds: 0.2) { pb, _ in frame = pb; return false }
        guard let f = frame else { return }
        let w = Double(CVPixelBufferGetWidth(f)), h = Double(CVPixelBufferGetHeight(f))
        for (dx, dy, roll) in [(10.0, 0.0, 0.0), (-24.0, 12.0, 0.0), (0.0, 0.0, 0.02), (30.0, -15.0, -0.03)] {
            let img = CIImage(cvPixelBuffer: f)
            let t = CGAffineTransform(translationX: -w / 2, y: -h / 2).concatenating(CGAffineTransform(rotationAngle: roll)).concatenating(CGAffineTransform(translationX: w / 2 + dx, y: h / 2 + dy))
            let moved = makeBuffer(Int(w), Int(h)); ci.render(img.transformed(by: t), to: moved, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let a = analysisBuffer(f, roi: 1, width: 640), b = analysisBuffer(moved, roi: 1, width: 640)
            let s = 640 / w
            print(String(format: "[selftest] truth dx %5.1f dy %5.1f roll %.3f", dx, dy, roll))
            for m in StabilizerMode.allCases { let r = measure(a, b, mode: m, scale: s); print(String(format: "[selftest]   %-22@ dx %6.1f dy %6.1f roll %.3f", m.rawValue as NSString, r.x, r.y, r.r)) }
            let r = flowMeasure(a, b); print(String(format: "[selftest]   %-22@ dx %6.1f dy %6.1f roll %.3f", "flow" as NSString, r.x / s, r.y / s, r.r))
        }
    }

    // MARK: file run: real frames through the real Stabilizer, output judged by the reference measurement

    static func parseTuning(_ spec: String) -> StabilizerTuning {
        var t = StabilizerTuning()
        for kv in spec.split(separator: ",") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { continue }
            switch p[0] {
            case "width": t.analysisWidth = Int(p[1]) ?? t.analysisWidth
            case "roi": t.analysisROI = Double(p[1]) ?? t.analysisROI
            case "gate": t.gate = Double(p[1]) ?? t.gate
            case "alpha": t.alphaOverride = Double(p[1])
            case "smoother":
                let q = p[1].split(separator: "/").map(String.init), a = q.count > 1 ? Double(q[1]) ?? 0 : 0, b = q.count > 2 ? Double(q[2]) ?? 0 : 0
                switch q[0] {
                case "double": t.smoother = .doubleEma
                case "oneeuro": t.smoother = .oneEuro(fMin: a, beta: b)
                case "holt": t.smoother = .holt(b: a)
                case "adaptive": t.smoother = .adaptive(aMin: a, vHi: b)
                default: t.smoother = .ema
                }
            default: break
            }
        }
        return t
    }

    /// Mean absolute difference (0...255, green channel) between two equally sized BGRA buffers.
    static func meanAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var s = 0
        for y in 0..<h { for x in 0..<w { s += abs(Int(pa[y * ra + x * 4 + 1]) - Int(pb[y * rb + x * 4 + 1])) } }
        return Double(s) / Double(w * h)
    }

    struct RunStats { var jit8 = 0.0, hpPx = 0.0, hpDeg = 0.0, stepPx = 0.0, mad = 0.0, crop = 0.0, msMean = 0.0, msMedian = 0.0, meanC = 0.0, outliers = 0, frames = 0 }

    /// `--stab-file f --start s --seconds n [--modes translation,similarity-homography] [--set key=val,...] [--strength 0.6] [--label x]`
    static func fileRun(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-file") else { return }
        if let sg = opt("--sigma").flatMap(Double.init) { StabMetrics.sigma = sg }
        let start = Double(opt("--start") ?? "0") ?? 0, secs = Double(opt("--seconds") ?? "30") ?? 30
        let strength = Double(opt("--strength") ?? "0.6") ?? 0.6
        let modes = (opt("--modes") ?? "off,translation,similarity-tiles,similarity-homography").split(separator: ",").map(String.init)
        let tuning = parseTuning(opt("--set") ?? "")
        let label = opt("--label") ?? (opt("--set") ?? "default")
        var inStats: RunStats?
        let url = URL(fileURLWithPath: file)
        for modeName in modes {
            let mode = StabilizerMode(rawValue: modeName)
            let st = Stabilizer(); st.tuning = tuning
            var prevRef: CVPixelBuffer?, prevMad: CVPixelBuffer?
            var dx = [Double](), dy = [Double](), dr = [Double](), mads = [Double](), msList = [Double]()
            decode(url, start: start, seconds: secs) { pb, ns in
                var shown = pb
                if let mode {
                    st.noteTimestamp(ns)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    shown = st.process(pb, strength: strength, mode: mode)
                    msList.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                let ref = analysisBuffer(shown, roi: refRoi, width: refWidth), madB = analysisBuffer(shown, roi: 0.8, width: 320)
                ci.clearCaches()
                if let p = prevRef {
                    let m = measure(p, ref, mode: .similarityHomography, scale: Double(refWidth) / (Double(CVPixelBufferGetWidth(pb)) * refRoi))
                    dx.append(m.ok ? m.x : 0); dy.append(m.ok ? m.y : 0); dr.append(m.ok ? m.r : 0)
                }
                if let p = prevMad { mads.append(meanAbsDiff(p, madB)) }
                prevRef = ref; prevMad = madB
                return true
            }
            var r = RunStats()
            r.frames = dx.count
            r.hpPx = StabMetrics.highpassRMS2D(dx: dx, dy: dy)
            r.jit8 = StabMetrics.meanNormHP(dx: dx, dy: dy)
            r.hpDeg = StabMetrics.highpassRMS(path: StabMetrics.cumulative(dr)) * 180 / .pi
            r.stepPx = zip(dx, dy).reduce(0.0) { $0 + hypot($1.0, $1.1) } / Double(max(1, dx.count))
            r.mad = mads.reduce(0, +) / Double(max(1, mads.count))
            let stats = st.stats
            r.crop = mode == nil ? 0 : (1 - 1 / stats.meanZoom) * 100
            r.meanC = stats.meanCorrectionPx; r.outliers = stats.outliers
            r.msMean = msList.reduce(0, +) / Double(max(1, msList.count)); r.msMedian = msList.sorted().isEmpty ? 0 : msList.sorted()[msList.count / 2]
            if mode == nil { inStats = r }
            let red = inStats.map { 100 * (1 - r.hpPx / max($0.hpPx, 1e-9)) } ?? 0
            print(String(format: "[file] %@ | %@ | jit8 %6.2f | hp %6.2f px (%+5.1f%%) | roll %.3f deg | step %5.2f | MAD %5.2f | crop %4.1f%% | |c| %5.1f | out %d | ms %5.2f (p50 %5.2f) | frames %d",
                         label, modeName, r.jit8, r.hpPx, -red, r.hpDeg, r.stepPx, r.mad, r.crop, r.meanC, r.outliers, r.msMean, r.msMedian, r.frames))
        }
    }

    /// `--stab-measure video [--start --seconds]`: the same output measurements for any video (e.g. the offline reference renders).
    static func measureVideo(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-measure") else { return }
        var prevRef: CVPixelBuffer?, prevMad: CVPixelBuffer?
        var dx = [Double](), dy = [Double](), dr = [Double](), mads = [Double]()
        var wd = 1.0
        decode(URL(fileURLWithPath: file), start: Double(opt("--start") ?? "0") ?? 0, seconds: Double(opt("--seconds") ?? "1000") ?? 1000) { pb, _ in
            wd = Double(CVPixelBufferGetWidth(pb))
            let ref = analysisBuffer(pb, roi: refRoi, width: refWidth), madB = analysisBuffer(pb, roi: 0.8, width: 320)
            ci.clearCaches()
            if let p = prevRef { let m = measure(p, ref, mode: .similarityHomography, scale: Double(refWidth) / (wd * refRoi)); dx.append(m.ok ? m.x : 0); dy.append(m.ok ? m.y : 0); dr.append(m.ok ? m.r : 0) }
            if let p = prevMad { mads.append(meanAbsDiff(p, madB)) }
            prevRef = ref; prevMad = madB
            return true
        }
        print(String(format: "[measure] %@ | w %.0f | jit8 %.2f | hp5 %.2f px | roll %.3f deg | step %.2f | MAD %.2f | frames %d", (file as NSString).lastPathComponent, wd,
                     StabMetrics.meanNormHP(dx: dx, dy: dy), StabMetrics.highpassRMS2D(dx: dx, dy: dy), StabMetrics.highpassRMS(path: StabMetrics.cumulative(dr)) * 180 / .pi,
                     zip(dx, dy).reduce(0.0) { $0 + hypot($1.0, $1.1) } / Double(max(1, dx.count)), mads.reduce(0, +) / Double(max(1, mads.count)), dx.count))
    }

    /// `--stab-bench file --start s`: cost of analysis render + registration for buffer formats / widths (200 frame pairs).
    static func bench(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-bench") else { return }
        var frames: [CVPixelBuffer] = []
        decode(URL(fileURLWithPath: file), start: Double(opt("--start") ?? "0") ?? 0, seconds: 3) { pb, _ in
            let c = makeBuffer(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetPixelFormatType(pb))
            ci.render(CIImage(cvPixelBuffer: pb), to: c); frames.append(c); return frames.count < 100 }
        print("[bench] \(frames.count) frames \(CVPixelBufferGetWidth(frames[0]))x\(CVPixelBufferGetHeight(frames[0]))")
        for (fmtName, fmt) in [("BGRA", kCVPixelFormatType_32BGRA), ("R8", kCVPixelFormatType_OneComponent8)] {
            for (roi, wd) in [(1.0, 640), (0.7, 640), (0.7, 480), (0.7, 384), (0.7, 320)] {
                var rMs = 0.0, mMs = 0.0, n = 0.0
                var prev: CVPixelBuffer?
                for f in frames {
                    let w = Double(CVPixelBufferGetWidth(f)), h = Double(CVPixelBufferGetHeight(f))
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let crop = CGRect(x: w * (1 - roi) / 2, y: h * (1 - roi) / 2, width: w * roi, height: h * roi), sc = Double(wd) / crop.width
                    let b = makeBuffer(wd, Int((crop.height * sc).rounded()), fmt)
                    ci.render(CIImage(cvPixelBuffer: f).cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: sc, y: sc))), to: b)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    if let p = prev { _ = Stabilizer.measure(from: p, to: b, mode: .similarityHomography); mMs += Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6; n += 1 }
                    rMs += Double(t1 - t0) / 1e6
                    prev = b
                }
                print(String(format: "[bench] %@ roi %.1f w %d: render %.2f ms, homography %.2f ms", fmtName, roi, wd, rMs / Double(frames.count), mMs / max(n, 1)))
            }
        }
    }

    // MARK: scan: shake per window over a whole clip (cheap translation estimator)

    static func scan(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let file = opt("--stab-scan") else { return }
        let win = Double(opt("--window") ?? "10") ?? 10
        var prev: CVPixelBuffer?
        var dx = [Double](), dy = [Double](), t0: Int64?
        var fails = 0
        func flush(_ t: Double) {
            guard dx.count > 20 else { dx = []; dy = []; return }
            let hp = StabMetrics.highpassRMS2D(dx: dx, dy: dy)
            let mean = zip(dx, dy).reduce(0.0) { $0 + hypot($1.0, $1.1) } / Double(dx.count)
            let big = zip(dx, dy).filter { hypot($0, $1) > 0.1 * 1920 }.count
            print(String(format: "[scan] t=%6.1f n=%4d meanMotion=%6.2f px highpass=%6.2f px  >10%%width=%d fails=%d", t, dx.count, mean, hp, big, fails))
            dx = []; dy = []
        }
        decode(URL(fileURLWithPath: file), start: Double(opt("--start") ?? "0") ?? 0, seconds: Double(opt("--seconds") ?? "100000") ?? 1e5) { pb, ns in
            let b = analysisBuffer(pb, roi: 1, width: 480)
            let k = 480.0 / Double(CVPixelBufferGetWidth(pb))
            if let p = prev {
                if let m = Stabilizer.measure(from: p, to: b) { dx.append(Double(m.x) / k); dy.append(Double(m.y) / k) } else { fails += 1 }
            }
            prev = b
            if t0 == nil { t0 = ns }
            if Double(ns - t0!) / 1e9 >= win { flush(Double(t0!) / 1e9); t0 = ns; fails = 0 }
            return true
        }
    }

    // MARK: sim: replay recorded estimator output through smoother variants (pure math, seconds instead of minutes)

    struct SimVariant {
        var name = ""
        var kind = PathSmoother.Kind.ema
        var alpha = 0.788, rollAlpha = 0.788
        var rollKind = PathSmoother.Kind.ema
        var gate = Stabilizer.maxPlausibleMotion
        var rollOn = false
        var look = 0
        var cap = StabilizerPrefs.margin(forStrength: 0.6)
        var resting = StabilizerPrefs.restingMargin
        var decay = 0.995
    }
    struct SimResult { var hpPx = 0.0, hpDeg = 0.0, stepPx = 0.0, crop = 0.0, clamp = 0.0, meanC = 0.0, lagPx = 0.0 }

    static func sim(est: [Meas], ref: [Meas], w: Double, h: Double, v: SimVariant) -> SimResult {
        func strengthFor(_ a: Double) -> Double { (a - 0.5) / 0.48 }
        var sm = PathSmoother(strength: strengthFor(v.alpha), kind: v.kind)
        var rs = PathSmoother(strength: strengthFor(v.rollAlpha), kind: v.rollKind, unitPx: 960)
        let tShare = v.rollOn ? 0.65 : 1.0
        var peak = 0.0
        var cx = [Double](), cy = [Double](), cr = [Double](), smx = [Double](), smy = [Double](), smr = [Double](), px = [Double](), py = [Double](), pr = [Double]()
        var needs = [Double]()
        var clamped = 0
        for m in est {
            var mo = CGPoint(x: m.ok ? m.x : 0, y: m.ok ? m.y : 0), rm = m.ok && v.rollOn ? m.r : 0
            if hypot(mo.x, mo.y) > v.gate * w || abs(rm) > Stabilizer.maxPlausibleRoll { mo = .zero; rm = 0 }
            let lim = CGSize(width: v.cap * tShare * w, height: v.cap * tShare * h)
            let c = sm.step(motion: mo, limit: lim)
            if abs(c.x) >= lim.width - 1e-6 || abs(c.y) >= lim.height - 1e-6 { clamped += 1 }
            var rc = 0.0
            if v.rollOn {
                let rl = CGFloat(0.7 * v.cap / max(w / h, h / w))
                rc = Double(rs.step(motion: CGPoint(x: rm, y: 0), limit: CGSize(width: rl, height: rl)).x)
                smr.append(Double(rs.smooth.x))
            } else { smr.append(0) }
            px.append(Double(sm.path.x)); py.append(Double(sm.path.y)); pr.append(Double(rs.path.x))
            smx.append(Double(sm.smooth.x)); smy.append(Double(sm.smooth.y))
            cx.append(Double(c.x)); cy.append(Double(c.y)); cr.append(rc)
        }
        let n = est.count
        // Look-ahead: frame i is shown with the smoothed value of frame i+look (clamped to the limit).
        var fx = cx, fy = cy, fr = cr
        if v.look > 0 {
            for i in 0..<n {
                let k = min(n - 1, i + v.look)
                let lim = v.cap * tShare
                fx[i] = min(max(smx[k] - px[i], -lim * w), lim * w); fy[i] = min(max(smy[k] - py[i], -lim * h), lim * h)
                fr[i] = v.rollOn ? smr[k] - pr[i] : 0
            }
        }
        for i in 0..<n {
            let need = max(abs(fx[i]) / w, abs(fy[i]) / h) + StabilizerPrefs.rollMargin(fr[i], w: w, h: h)
            peak = max(need, peak * v.decay); needs.append(min(v.cap, max(v.resting, peak + 0.01)))
        }
        let zoom = needs.reduce(0.0) { $0 + 1 / (1 - 2 * $1) } / Double(max(1, n))
        // Output path as the viewer sees it: the independent reference path plus the correction applied.
        var rx = 0.0, ry = 0.0, rr = 0.0
        var ox = [Double](), oy = [Double](), orr = [Double](), ix = [Double](), iy = [Double](), ir = [Double]()
        for i in 0..<min(n, ref.count) {
            rx += ref[i].x; ry += ref[i].y; rr += ref[i].r
            ix.append(rx); iy.append(ry); ir.append(rr)
            ox.append(rx + fx[i]); oy.append(ry + fy[i]); orr.append(rr + fr[i])
        }
        func hp2(_ a: [Double], _ b: [Double]) -> Double { let u = StabMetrics.highpassRMS(path: a), t = StabMetrics.highpassRMS(path: b); return (u * u + t * t).squareRoot() }
        var steps = 0.0
        for i in 1..<ox.count { steps += hypot(ox[i] - ox[i - 1], oy[i] - oy[i - 1]) }
        let gx = StabMetrics.gaussianSmooth(ix, sigma: StabMetrics.sigma), gy = StabMetrics.gaussianSmooth(iy, sigma: StabMetrics.sigma)
        let tracking = (0..<ox.count).reduce(0.0) { $0 + hypot(ox[$1] - gx[$1], oy[$1] - gy[$1]) }
        return SimResult(hpPx: hp2(ox, oy), hpDeg: StabMetrics.highpassRMS(path: orr) * 180 / .pi, stepPx: steps / Double(max(1, ox.count - 1)),
                         crop: (1 - 1 / zoom) * 100, clamp: 100 * Double(clamped) / Double(max(1, n)),
                         meanC: zip(fx, fy).reduce(0.0) { $0 + hypot($1.0, $1.1) } / Double(max(1, n)), lagPx: tracking / Double(max(1, ox.count)))
    }

    static func loadCSV(_ path: String) -> [String: [Meas]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        let lines = text.split(separator: "\n")
        let heads = lines[0].split(separator: ",").map(String.init)
        var out: [String: [Meas]] = [:]
        for l in lines.dropFirst() {
            let v = l.split(separator: ",").map { Double($0) ?? 0 }
            var j = 0
            while j + 2 < heads.count {
                let key = String(heads[j].dropLast(2))
                out[key, default: []].append(Meas(x: v[j], y: v[j + 1], r: v[j + 2]))
                j += 3
            }
        }
        return out
    }

    /// `--stab-sim a.csv,b.csv --w 1920 --h 1080 --est "translation|1.0|640|clean" --sweep "name:kind:alpha:p1:p2:gate:look ..."`
    static func simCommand(args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let sg = opt("--sigma").flatMap(Double.init) { StabMetrics.sigma = sg }
        guard let files = opt("--stab-sim")?.split(separator: ",").map(String.init) else { return }
        let w = Double(opt("--w") ?? "1920") ?? 1920, h = Double(opt("--h") ?? "1080") ?? 1080
        var refKey = "similarity-homography|\(refRoi)|\(refWidth)|clean"
        let refFile = opt("--refcsv")
        if refFile != nil { refKey = "flow|1.0|640|clean" }
        let extra = refFile.map { loadCSV($0) } ?? [:]
        for est in (opt("--est") ?? "translation|1.0|640|clean").split(separator: ";").map(String.init) {
        print("[sim] == \(est)")
        for spec in (opt("--sweep") ?? "ema:0.788").split(separator: " ").map(String.init) {
            var v = SimVariant()
            let f = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            v.name = spec
            v.alpha = Double(f.count > 1 ? f[1] : "") ?? 0.788
            let p1 = Double(f.count > 2 ? f[2] : "") ?? 0, p2 = Double(f.count > 3 ? f[3] : "") ?? 0
            switch f[0] {
            case "adaptive": v.kind = .adaptive(aMin: p1, vHi: p2)
            case "holt": v.kind = .holt(b: p1)
            case "oneeuro": v.kind = .oneEuro(fMin: p1, beta: p2)
            case "double": v.kind = .doubleEma
            default: v.kind = .ema
            }
            if f.count > 4, let g = Double(f[4]), g > 0 { v.gate = g }
            if f.count > 5, let l = Int(f[5]) { v.look = l }
            v.rollOn = est.hasPrefix("similarity")
            v.rollAlpha = v.alpha
            if f.count > 6, let ra = Double(f[6]) { if ra <= 0 { v.rollOn = false } else { v.rollAlpha = ra } }
            if f.count > 7, let x = Double(f[7]) { v.resting = x }
            if f.count > 8, let x = Double(f[8]) { v.decay = x }
            if f.count > 9, let x = Double(f[9]) { v.cap = x }
            var tot = SimResult(), n = 0.0, inPx = 0.0, inDeg = 0.0, inStep = 0.0
            for file in files {
                var d = loadCSV(file)
                d.merge(extra) { a, _ in a }
                guard let e = d[est], let r = d[refKey] else { continue }
                let x = sim(est: e, ref: r, w: w, h: h, v: v)
                let ix = r.map { $0.x }, iy = r.map { $0.y }, ir = r.map { $0.r }
                inPx += StabMetrics.highpassRMS2D(dx: ix, dy: iy); inDeg += StabMetrics.highpassRMS(path: StabMetrics.cumulative(ir)) * 180 / .pi
                inStep += zip(ix, iy).reduce(0.0) { $0 + hypot($1.0, $1.1) } / Double(r.count)
                tot.hpPx += x.hpPx; tot.hpDeg += x.hpDeg; tot.stepPx += x.stepPx; tot.crop += x.crop; tot.clamp += x.clamp; tot.meanC += x.meanC; tot.lagPx += x.lagPx; n += 1
            }
            guard n > 0 else { print("no data for \(est)"); break }
            if spec == "corr" || args.contains("--corr") {
                for file in files {
                    var d = loadCSV(file); d.merge(extra) { a, _ in a }
                    guard let e = d[est], let r = d[refKey] else { continue }
                    func corr(_ a: [Double], _ b: [Double]) -> Double {
                        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
                        var sab = 0.0, saa = 0.0, sbb = 0.0
                        for (x, y) in zip(a, b) { sab += (x - ma) * (y - mb); saa += (x - ma) * (x - ma); sbb += (y - mb) * (y - mb) }
                        return sab / max(1e-9, (saa * sbb).squareRoot())
                    }
                    let n = min(e.count, r.count)
                    let med = { (v: [Double]) in v.sorted()[v.count / 2] }
                    print(String(format: "[corr] %@ corr x %.2f y %.2f roll %.2f | median |est| %.1f |ref| %.1f | median |est-ref| %.1f px", est, corr(e.prefix(n).map { $0.x }, r.prefix(n).map { $0.x }), corr(e.prefix(n).map { $0.y }, r.prefix(n).map { $0.y }), corr(e.prefix(n).map { $0.r }, r.prefix(n).map { $0.r }), med(e.prefix(n).map { hypot($0.x, $0.y) }), med(r.prefix(n).map { hypot($0.x, $0.y) }), med((0..<n).map { hypot(e[$0].x - r[$0].x, e[$0].y - r[$0].y) })))
                }
            }
            print(String(format: "[sim] %-38@ hp %6.2f px (in %6.2f) | roll %.3f deg (in %.3f) | step %5.1f (in %5.1f) | crop %4.1f%% | clamp %4.1f%% | |c| %5.1f | dev %5.1f", v.name as NSString, tot.hpPx / n, inPx / n, tot.hpDeg / n, inDeg / n, tot.stepPx / n, inStep / n, tot.crop / n, tot.clamp / n, tot.meanC / n, tot.lagPx / n))
        }
        }
    }
}
