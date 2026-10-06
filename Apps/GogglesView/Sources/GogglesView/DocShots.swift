#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// Dev aid for documentation screenshots of windows that normally need live goggles.
/// `GogglesView --doc-shot <clip-gallery|mini-window|menu-bar|live-synthetic> <out.png>`
/// Uses generated pictures and a temporary recordings folder; no helper, no XPC. Defaults written
/// into the unbundled binary's own domain are removed again before exiting. Not used in normal runs.
enum DocShots {
    static let ci = CIContext()

    // MARK: synthetic pictures

    /// Smooth outdoor-like scene: sky gradient, soft sun glow, layered hills. `shift` varies hue and layout.
    static func scene(width: Int, height: Int, shift: Double = 0) -> CIImage {
        let w = CGFloat(width), h = CGFloat(height)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        func color(_ r: Double, _ g: Double, _ b: Double) -> CIColor { CIColor(red: r, green: g, blue: b) }
        let sky = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: h), "inputPoint1": CIVector(x: 0, y: h * 0.35),
            "inputColor0": color(0.18 + 0.1 * shift, 0.42, 0.78 - 0.2 * shift),
            "inputColor1": color(0.92, 0.78 - 0.2 * shift, 0.6 - 0.1 * shift)])!.outputImage!.cropped(to: rect)
        let sun = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: w * (0.3 + 0.4 * shift), y: h * 0.5), "inputRadius0": h * 0.03, "inputRadius1": h * 0.35,
            "inputColor0": CIColor(red: 1, green: 0.95, blue: 0.8, alpha: 0.95),
            "inputColor1": CIColor(red: 1, green: 0.8, blue: 0.5, alpha: 0)])!.outputImage!.cropped(to: rect)
        var img = sun.composited(over: sky)
        let layers: [(Double, Double, Double, Double, Double)] = [
            (0.50, 0.30, 0.38, 0.52, 0.62), (0.40, 0.20, 0.30, 0.45, 0.38), (0.30, 0.10, 0.22, 0.34, 0.2)]
        for (i, l) in layers.enumerated() {
            let base = h * l.0, amp = h * 0.07 * (1 + Double(i) * 0.4)
            let freq = 2.0 + Double(i) + shift * 3, phase = Double(i) * 1.7 + shift * 5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= w {
                path.addLine(to: CGPoint(x: x, y: base + amp * sin(Double(x / w) * freq * .pi + phase)))
                x += 4
            }
            path.addLine(to: CGPoint(x: w, y: 0)); path.closeSubpath()
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(red: l.2 * 0.6, green: l.3, blue: l.4 * (1 - shift * 0.5), alpha: 1))
            ctx.addPath(path); ctx.fillPath()
            img = CIImage(cgImage: ctx.makeImage()!).composited(over: img)
        }
        return img.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]).cropped(to: rect)
    }

    static func pixelBuffer(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        ci.render(image, to: pb!)
        return pb!
    }

    // MARK: fake clips

    static func makeClip(at url: URL, seconds: Double, shift: Double) throws {
        let (w, h, fps) = (640, 360, 10)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let base = scene(width: w + 120, height: h, shift: shift)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let dx = CGFloat(i % 120)
            let frame = base.transformed(by: CGAffineTransform(translationX: -dx, y: 0)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            adaptor.append(pixelBuffer(frame, width: w, height: h), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }

    // MARK: capture

    static func findVideoHost(in v: NSView) -> SampleBufferHostView? {
        if let h = v as? SampleBufferHostView { return h }
        for sub in v.subviews { if let h = findVideoHost(in: sub) { return h } }
        return nil
    }

    /// View snapshot as PNG. Display layers are not captured by `cacheDisplay`, so when `picture` is given it is
    /// drawn (aspect-fit, optional rounded corners) into the video host view's rectangle afterwards.
    static func snapshot(view: NSView, to out: URL, picture: CGImage? = nil, cornerRadius: CGFloat = 0) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let picture, let host = findVideoHost(in: view), let gc = NSGraphicsContext(bitmapImageRep: rep) {
            let r = host.convert(host.bounds, to: view)
            let scale = CGFloat(picture.width) / CGFloat(picture.height)
            var fit = r
            if r.width / r.height > scale { fit.size.width = r.height * scale; fit.origin.x += (r.width - fit.width) / 2 }
            else { fit.size.height = r.width / scale; fit.origin.y += (r.height - fit.height) / 2 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            if cornerRadius > 0 { NSBezierPath(roundedRect: fit, xRadius: cornerRadius, yRadius: cornerRadius).addClip() }
            gc.cgContext.interpolationQuality = .high
            gc.cgContext.draw(picture, in: fit)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }

    /// Removes fully transparent margins and rewrites the PNG.
    static func cropTransparent(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return }
        let r = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = img.cropping(to: r), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cropped, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: entry

    static func run(name: String, out: URL) -> Never {
        let d = UserDefaults.standard
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var tmp: URL?
        func finish(_ ok: Bool) -> Never {
            for k in [RecordingPrefs.folderKey, MiniWindowPrefs.enabledKey, "NSWindow Frame \(MiniWindowPrefs.frameName)"] { d.removeObject(forKey: k) }
            if let tmp { try? FileManager.default.removeItem(at: tmp) }
            if ok { cropTransparent(out) }
            print(ok ? "wrote \(out.path)" : "doc-shot failed")
            exit(ok ? 0 : 1)
        }
        let session = DecodeSession()
        let frame = pixelBuffer(scene(width: 1920, height: 1080), width: 1920, height: 1080)
        var window: NSWindow?
        var delay = 2.0

        switch name {
        case "clip-gallery":
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doc-shot-clips", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tmp = dir
            let specs: [(String, Double, Double)] = [
                ("Morning-flight", 34, 0.0), ("Harbour-run", 21, 0.2), ("Ridge-line", 48, 0.4),
                ("Beach-pass", 12, 0.6), ("Forest-gap", 27, 0.8), ("Sunset-loop", 16, 1.0)]
            let now = Date()
            for (i, s) in specs.enumerated() {
                let u = dir.appendingPathComponent("\(s.0).mov")
                do { try makeClip(at: u, seconds: s.1, shift: s.2) } catch { finish(false) }
                let date = now.addingTimeInterval(-Double(i) * 86_400 * 1.3 - 3600)
                try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: u.path)
            }
            d.set(dir.path, forKey: RecordingPrefs.folderKey)
            ClipGalleryWindowController.shared.show()
            window = NSApp.windows.first { $0.title == "Clip Gallery" }
            window?.setContentSize(NSSize(width: 820, height: 620))
            delay = 3
        case "mini-window":
            d.set(true, forKey: MiniWindowPrefs.enabledKey)
            MiniWindowController.shared.sync(session: session)
            window = NSApp.windows.first { $0.title == "GogglesView Mini" }
        case "menu-bar":
            let snap = MiniControlsSnapshot(label: "DJI Goggles 3", statusText: "Live", isLive: true, fps: 60, batteryPercent: 83,
                                            isRecording: true, recordingElapsed: 83, networkStreamAvailable: true, replayEnabled: true)
            let host = NSHostingView(rootView: MenuMock(snap: snap))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.backgroundColor = .clear
            w.makeKeyAndOrderFront(nil)
            window = w
            delay = 1
        case "live-synthetic":
            let client = HelperClient()
            let coordinator = GogglesConnectionCoordinator(client: client, deviceId: "doc-shot", startWatchdog: false)
            coordinator.forceState(.live)
            let hosting = NSHostingController(rootView: GogglesConnectionView(coordinator: coordinator, session: session))
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.title = "GogglesView"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 960, height: 620))
            applyCustomTitleBarChrome(to: w)
            w.center(); w.makeKeyAndOrderFront(nil)
            window = w
        default:
            print("unknown doc-shot '\(name)'"); exit(1)
        }
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { session.injectDecodedFrame(frame) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { session.injectDecodedFrame(frame) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) {
            guard let window else { finish(false) }
            let pic = name == "clip-gallery" || name == "menu-bar" ? nil
                : ci.createCGImage(CIImage(cvPixelBuffer: frame), from: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let ok = (window.contentView?.superview).map {
                snapshot(view: $0, to: out, picture: pic, cornerRadius: name == "mini-window" ? 12 : 0) } ?? false
            finish(ok)
        }
        app.run()
        exit(0)
    }
}

/// Static look-alike of the status-item submenu, built from the same `MenuBarMiniControls` titles and rules.
private struct MenuMock: View {
    let snap: MiniControlsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MenuBarMiniControls.headerTitle(snap)).fontWeight(.semibold).padding(.horizontal, 22).padding(.vertical, 4)
            Text(MenuBarMiniControls.infoLine(snap)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 3)
            Divider().padding(.vertical, 3)
            ForEach(Array(MenuBarMiniControls.items(snap).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 0) {
                    Text(item.isOn ? "✓" : "").frame(width: 22)
                    Text(item.title)
                    Spacer(minLength: 24)
                    if item.action == .addMarker { Text("›") }
                }
                .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary.opacity(0.7))
                .padding(.vertical, 3).padding(.trailing, 12)
                if item.action == .addMarker { Divider().padding(.vertical, 3) }
            }
            Divider().padding(.vertical, 3)
            Text("Reconnect").padding(.horizontal, 22).padding(.vertical, 3)
            Text("Disconnect").padding(.horizontal, 22).padding(.vertical, 3)
        }
        .font(.system(size: 14))
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
        .padding(1)
    }
}
#endif
