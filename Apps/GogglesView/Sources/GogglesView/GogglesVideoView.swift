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
    let displayLayer = AVSampleBufferDisplayLayer()

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
        layer?.addSublayer(displayLayer)
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

    @objc private func orientationChanged() { needsLayout = true }

    override func layout() {
        super.layout()
        let r = OrientationPrefs.rotation
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = OrientationPrefs.swapsAxes(r) ? CGRect(x: 0, y: 0, width: h, height: w) : CGRect(x: 0, y: 0, width: w, height: h)
        displayLayer.position = CGPoint(x: w / 2, y: h / 2)
        displayLayer.setAffineTransform(OrientationPrefs.transform(rotation: r, flipH: OrientationPrefs.flipH, flipV: OrientationPrefs.flipV))
        CATransaction.commit()
        return
        // The backing layer doesn't auto-follow the view's frame the way a
        // normal `CALayer` sublayer would via autoresizing masks -- since
        // `displayLayer` IS `self.layer`, AppKit already keeps its
        // `bounds`/`frame` synced with the view automatically; nothing
        // further needed here. Kept as an explicit override (rather than
        // omitted) so a future reviewer sees this was considered, not
        // missed.
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
        if isSecondary {
            session.addConsumer(view.displayLayer)
        } else {
            session.attach(renderer: view.displayLayer)
        }
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
