#if canImport(AppKit)
import AppKit
import SwiftUI

/// Rotation/flip applied to the video in every window that shows it (for
/// upside-down or mirrored mounts). Stored in UserDefaults.
enum OrientationPrefs {
    static let rotationKey = "viewRotation"
    static let flipHKey = "viewFlipH"
    static let flipVKey = "viewFlipV"
    static let hideCursorKey = "hideCursorFullscreen"

    static var rotation: Int {
        let r = UserDefaults.standard.integer(forKey: rotationKey)
        return [0, 90, 180, 270].contains(r) ? r : 0
    }
    static var flipH: Bool { UserDefaults.standard.bool(forKey: flipHKey) }
    static var flipV: Bool { UserDefaults.standard.bool(forKey: flipVKey) }
    static var hideCursor: Bool {
        UserDefaults.standard.object(forKey: hideCursorKey) as? Bool ?? true
    }

    /// Flip first (in the video's own axes), then rotate clockwise.
    static func transform(rotation: Int, flipH: Bool, flipV: Bool) -> CGAffineTransform {
        var t = CGAffineTransform(scaleX: flipH ? -1 : 1, y: flipV ? -1 : 1)
        t = t.concatenating(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
        return t
    }

    static func swapsAxes(_ rotation: Int) -> Bool { rotation == 90 || rotation == 270 }
}

struct OrientationSettingsSection: View {
    @AppStorage(OrientationPrefs.rotationKey) private var rotation = 0
    @AppStorage(OrientationPrefs.flipHKey) private var flipH = false
    @AppStorage(OrientationPrefs.flipVKey) private var flipV = false
    @AppStorage(OrientationPrefs.hideCursorKey) private var hideCursor = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Orientation and full screen").font(.headline)
            Picker("Rotate", selection: $rotation) {
                Text("0°").tag(0)
                Text("90°").tag(90)
                Text("180°").tag(180)
                Text("270°").tag(270)
            }
            .pickerStyle(.segmented)
            Toggle("Flip horizontally", isOn: $flipH)
            Toggle("Flip vertically", isOn: $flipV)
            Toggle("Hide cursor when idle in full screen", isOn: $hideCursor)
            Text("Orientation applies to the main and capture windows, not to recordings or screenshots.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Hides the cursor after a short idle period while the window is full screen.
final class CursorAutoHider {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var monitor: Any?

    init(window: NSWindow, idleSeconds: TimeInterval = 2) {
        self.window = window
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown]) { [weak self] event in
            self?.arm(idleSeconds)
            return event
        }
        arm(idleSeconds)
    }

    private func arm(_ idle: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: idle, repeats: false) { [weak self] _ in
            guard let window = self?.window, OrientationPrefs.hideCursor,
                  window.styleMask.contains(.fullScreen) else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
#endif
