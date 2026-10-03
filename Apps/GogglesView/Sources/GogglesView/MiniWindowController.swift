#if canImport(AppKit)
import AppKit
import SwiftUI

enum MiniWindowPrefs {
    static let enabledKey = "miniWindowEnabled"
    static let frameName = "GogglesMiniWindow"
}

private final class MiniWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Always-on-top "picture in picture" window. Another secondary consumer of the shared `DecodeSession`;
/// being its own NSWindow it keeps working while the main window is hidden.
final class MiniWindowController: NSObject, NSWindowDelegate {
    static let shared = MiniWindowController()
    private var window: NSWindow?
    private var session: DecodeSession?

    /// Apply the saved preference for `session` (rebuilds if the session changed, e.g. after re-picking goggles).
    func sync(session: DecodeSession) {
        if self.session !== session { hide(); self.session = session }
        if UserDefaults.standard.bool(forKey: MiniWindowPrefs.enabledKey) { show() } else { hide() }
    }

    private func show() {
        guard let session else { return }
        guard window == nil else { window?.orderFront(nil); return }
        let host = NSHostingController(rootView: MiniWindowContent(session: session) { [weak self] in
            UserDefaults.standard.set(false, forKey: MiniWindowPrefs.enabledKey)
            self?.hide()
        })
        host.sizingOptions = []
        let w = MiniWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                           styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "GogglesView Mini"
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.contentMinSize = NSSize(width: 240, height: 135)
        w.delegate = self
        w.setContentSize(NSSize(width: 480, height: 270))
        if !w.setFrameUsingName(MiniWindowPrefs.frameName) { w.center() }
        w.setFrameAutosaveName(MiniWindowPrefs.frameName)
        window = w
        w.orderFront(nil)
    }

    private func hide() {
        guard let w = window else { return }
        w.delegate = nil
        w.orderOut(nil)
        w.contentViewController = nil  // drops the display layer -> weak consumer disappears
        window = nil
    }
}

private struct MiniWindowContent: View {
    let session: DecodeSession
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        GogglesVideoView(session: session, isSecondary: true)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain).padding(8).help("Close mini window")
                }
            }
            .onHover { hovering = $0 }
    }
}

/// Footer button (⇧⌘M). Also hands the session to the controller.
struct MiniWindowControl: View {
    let session: DecodeSession
    @AppStorage(MiniWindowPrefs.enabledKey) private var enabled = false

    var body: some View {
        Button { enabled.toggle() } label: {
            Image(systemName: "pip").foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help("Floating mini window (⇧⌘M)")
        .onAppear { MiniWindowController.shared.sync(session: session) }
        .onChange(of: enabled) { _, _ in MiniWindowController.shared.sync(session: session) }
    }
}

struct MiniWindowSettingsSection: View {
    @AppStorage(MiniWindowPrefs.enabledKey) private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Floating mini window (picture in picture, ⇧⌘M)", isOn: $enabled)
            Text("Always-on-top 16:9 video window; drag anywhere, resize from the edges, hover for the close button.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
