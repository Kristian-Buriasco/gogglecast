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

    // MARK: file run: real frames through the real Stabilizer, output judged by the reference measurement

    static func parseTuning(_ spec: String) -> StabilizerTuning {
        var t = StabilizerTuning()
        for kv in spec.split(separator: ",") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { continue }
            switch p[0] {
            case "width": t.analysisWidth = Int(p[1]) ?? t.analysisWidth
            case "roi": t.analysisROI = Double(p[1]) ?? t.analysisROI
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
}
