#if canImport(AppKit)
import AppKit
import SwiftUI

/// The "Connection health" window. One at a time, pointed at the key goggles
/// session (`BenchmarkRouting.targetProvider`). Closing it stops collection.
enum HealthWindow {
    private static var window: NSWindow?
    private static var model: ConnectionHealthModel?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        guard let target = BenchmarkRouting.targetProvider?() else {
            let alert = NSAlert()
            alert.messageText = L("No goggles window is open")
            alert.informativeText = L("Open your goggles and wait for the live picture, then open Connection health.")
            alert.runModal()
            return
        }
        let model = ConnectionHealthModel(target: target)
        model.start()
        let host = NSHostingController(rootView: ConnectionHealthView(model: model))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = L("Connection health")
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 600, height: 720))
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            model.stop()
            window?.contentViewController = nil
            window = nil
            Self.model = nil
        }
        Self.model = model
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Settings > Advanced card.
struct ConnectionHealthSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection health").font(.headline)
            HStack {
                Button("Open connection health…") { HealthWindow.show() }
                Spacer()
            }
            Text("Live frame rate, bitrate, frame gaps and dropped frames, with tips for cables, ports and hubs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
