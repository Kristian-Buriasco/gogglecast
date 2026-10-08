import SwiftUI
import AVFoundation

// ─────────────────────────────────────────────────────────────────────────
// Task 3.3: the `AVSampleBufferDisplayLayer`-backed rendering surface,
// wrapped as an `NSViewRepresentable` so a later SwiftUI app shell (Task
// 3.4/3.6) can drop it straight into a real window. Building that shell is
// explicitly NOT this task's job (brief point 3) -- this file stops at "a
// minimal host... enough to prove the layer renders in a visible window,"
// which `main.swift --live-view` (also this task) uses for hardware
// verification.
// ─────────────────────────────────────────────────────────────────────────

#if canImport(AppKit)
import AppKit

/// An `NSView` whose backing layer IS the `AVSampleBufferDisplayLayer` --
/// Apple's documented pattern (`makeBackingLayer()`/direct `layer =`
/// assignment) for hosting a display layer without an extra passthrough
/// `CALayer` in between.
final class SampleBufferHostView: NSView {
    let displayLayer = FreezableDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer = CALayer()
        clipLayer.addSublayer(displayLayer)
        exposureLayer.magnificationFilter = .nearest
        exposureLayer.isHidden = true
        clipLayer.addSublayer(exposureLayer)
        layer?.addSublayer(clipLayer)
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        gridLayer.fillColor = nil
        gridLayer.lineWidth = 1
        layer?.addSublayer(gridLayer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged), name: UserDefaults.didChangeNotification, object: nil)
        // Preserve 1920x1080 aspect rather than stretching to fill an
        // arbitrary host-window size (brief point 5: "matches expected
        // 1920x1080 aspect/orientation").
        displayLayer.videoGravity = .resizeAspect
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFailedToDecode(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Wired to `DecodeSession.recordExternalFailure(_:)` by
    /// `GogglesVideoView.Coordinator` -- VideoToolbox's own async decode
    /// errors (design §7's "VideoToolbox `OSStatus` error" row) don't
    /// surface synchronously from `enqueue(_:)`; this notification is how
    /// `AVSampleBufferDisplayLayer` reports them.
    var onFailedToDecode: ((Error) -> Void)?

    @objc private func handleFailedToDecode(_ notification: Notification) {
        let error = notification.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error
        onFailedToDecode?(error ?? DecodeSessionError.sampleBufferCreationFailed(-1))
    }

    private var prefsWork: DispatchWorkItem?

    /// Any preference change (rotation, framing, colour, LUT name/intensity/toggles) re-lays out the picture and
    /// re-applies the colour filters, so the preview follows Settings live. Coalesced on the main queue.
    @objc private func orientationChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prefsWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.displayLayer.filters = FramingPrefs.colorFilters()
                self.needsLayout = true
            }
            self.prefsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    // MARK: Framing (crop / zoom / pan / grid / color)

    /// Clips the picture to the crop window (aspect modes); `displayLayer` lives inside it.
    private let clipLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    /// Zebra and focus-peaking overlay; mirrors the picture's geometry so it follows rotation, zoom and pan.
    private let exposureLayer = CALayer()

    override func layout() {
        super.layout()
        let r = OrientationPrefs.rotation
        let aspect = FramingPrefs.aspect
        let zoom = FramingPrefs.zoom
        let crop = FramingGeometry.cropRect(in: bounds.size, ratio: aspect.ratio)
        let w = crop.width, h = crop.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.masksToBounds = true
        clipLayer.frame = crop
        displayLayer.videoGravity = (aspect == .fit) ? .resizeAspect : .resizeAspectFill
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = OrientationPrefs.swapsAxes(r) ? CGRect(x: 0, y: 0, width: h, height: w) : CGRect(x: 0, y: 0, width: w, height: h)
        displayLayer.position = CGPoint(x: w / 2, y: h / 2)
        // Orientation first, then zoom about the center, then pan (in view axes).
        let dx = FramingGeometry.offset(pan: FramingPrefs.panX, zoom: zoom, extent: w)
        let dy = FramingGeometry.offset(pan: FramingPrefs.panY, zoom: zoom, extent: h)
        let pictureTransform = OrientationPrefs.transform(rotation: r, flipH: OrientationPrefs.flipH, flipV: OrientationPrefs.flipV)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        displayLayer.setAffineTransform(pictureTransform)
        exposureLayer.setAffineTransform(.identity)
        exposureLayer.bounds = displayLayer.bounds
        exposureLayer.position = displayLayer.position
        exposureLayer.contentsGravity = aspect == .fit ? .resizeAspect : .resizeAspectFill
        exposureLayer.setAffineTransform(pictureTransform)
        // Layer filters on an AVSampleBufferDisplayLayer are untested with live video.
        displayLayer.filters = FramingPrefs.colorFilters()

        let path = CGMutablePath()
        for (a, b) in FramingGeometry.gridLines(in: crop, mode: RaceModePrefs.enabled ? .off : FramingPrefs.grid) {
            path.move(to: a); path.addLine(to: b)
        }
        gridLayer.frame = bounds
        gridLayer.path = path
        CATransaction.commit()
    }

    /// Shows (or clears) the exposure overlay from the analyzer.
    func setExposureOverlay(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        exposureLayer.contents = image
        exposureLayer.isHidden = image == nil
        CATransaction.commit()
    }

    // MARK: Interaction

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        applyZoom(FramingPrefs.zoom + event.scrollingDeltaY * step)
    }

    override func magnify(with event: NSEvent) {
        applyZoom(FramingPrefs.zoom * (1 + event.magnification))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { FramingPrefs.resetView() } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        let zoom = FramingPrefs.zoom
        guard zoom > 1 else { return }
        let crop = FramingGeometry.cropRect(in: bounds.size, ratio: FramingPrefs.aspect.ratio)
        let px = FramingGeometry.pan(FramingPrefs.panX, dragging: event.deltaX, zoom: zoom, extent: crop.width)
        // AppKit deltaY is positive downward; layer space is y-up.
        let py = FramingGeometry.pan(FramingPrefs.panY, dragging: -event.deltaY, zoom: zoom, extent: crop.height)
        FramingPrefs.panX = px
        FramingPrefs.panY = py
    }

    private func applyZoom(_ z: CGFloat) {
        FramingPrefs.zoom = z
        if FramingPrefs.zoom <= 1 { FramingPrefs.panX = 0; FramingPrefs.panY = 0 }
    }
}

/// SwiftUI host for `SampleBufferHostView`. Owns nothing decode-related
/// itself -- `session` is created and driven by the caller (see
/// `main.swift --live-view`), this view just attaches the freshly-created
/// `AVSampleBufferDisplayLayer` to it once the backing `NSView` exists, and
/// wires async decode-failure notifications back into the same session.
struct GogglesVideoView: NSViewRepresentable {
    let session: DecodeSession
    /// `true` for additional windows (e.g. the capture window): registers as
    /// an extra consumer instead of replacing the primary renderer.
    var isSecondary = false

    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.displayLayer.freezeState = session.freezeState
        if isSecondary {
            session.addConsumer(view.displayLayer)
        } else {
            session.attach(renderer: view.displayLayer)
        }
        session.addExposureSink(owner: view) { [weak view] image in view?.setExposureOverlay(image) }
        view.onFailedToDecode = { [weak session] error in
            session?.recordExternalFailure(error)
        }
        return view
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        // Nothing to sync per-update -- `session` drives the layer directly
        // via `enqueue(_:)` outside SwiftUI's render cycle (this is a live
        // feed, not state-driven SwiftUI content).
    }
}
#endif
