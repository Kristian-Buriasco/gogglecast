#if canImport(AppKit)
import AppKit

/// Small non-modal, non-activating notice that fades out on its own. Used for events the user did not
/// trigger from the UI (e.g. a `gogglesview://` command), so they are never silent.
final class ToastHUD {
    static let shared = ToastHUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Safe to call from any thread.
    func show(_ text: String, duration: TimeInterval = 3) {
        DispatchQueue.main.async { self.showOnMain(text, duration: duration) }
    }

    private func showOnMain(_ text: String, duration: TimeInterval) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.preferredMaxLayoutWidth = 380
        let size = label.fittingSize
        let pad: CGFloat = 14
        let frame = NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 1.4)
        label.frame = NSRect(x: pad, y: pad * 0.7, width: size.width, height: size.height)

        let box = NSView(frame: frame)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        box.layer?.cornerRadius = 10
        box.addSubview(label)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = box
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.maxY - frame.height - 24))
        }
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem { [weak self, weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
                if self?.panel === p { self?.panel = nil }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
#endif
