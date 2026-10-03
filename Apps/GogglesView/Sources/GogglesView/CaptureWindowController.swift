#if canImport(AppKit)
import AppKit
import SwiftUI

/// UserDefaults keys for the capture-window preferences (shared by Settings and launch wiring).
enum CaptureWindowPrefs {
    static let enabledKey = "captureWindowEnabled"
    static let onTopKey = "captureWindowOnTop"
}

/// Borderless NSWindow that can take key status (borderless windows can't by default),
/// which is what makes it draggable-by-background and resizable.
private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A chrome-less, video-only window for OBS "Window Capture" (free alternative to a virtual camera).
/// Registers as a secondary consumer of the `DecodeSession`; the hosting controller (and with it
/// the display layer, which the session only holds weakly) is torn down on `hide()`.
final class CaptureWindowController: NSObject, NSWindowDelegate {
    private let session: DecodeSession
    private var window: NSWindow?
    private var savedFrame: NSRect?

    var keepOnTop = false {
        didSet { window?.level = keepOnTop ? .floating : .normal }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    init(session: DecodeSession) {
        self.session = session
    }

    func show() {
        guard window == nil else {
            window?.orderFront(nil)
            return
        }
        // Fresh hosting view each time so a new display layer registers with the session;
        // it shows garbage until the next keyframe arrives.
        let host = NSHostingController(rootView: GogglesVideoView(session: session, isSecondary: true))
        host.sizingOptions = []
        let window = CaptureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "GogglesView Capture"  // OBS lists windows by title
        window.backgroundColor = .black
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.level = keepOnTop ? .floating : .normal
        window.delegate = self
        if let savedFrame {
            window.setFrame(savedFrame, display: false)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 720))
            window.center()
        }
        self.window = window
        window.orderFront(nil)
    }

    func hide() {
        guard let window else { return }
        savedFrame = window.frame
        window.delegate = nil
        window.orderOut(nil)
        window.contentViewController = nil  // drops the display layer -> weak consumer disappears
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }
}
#endif
