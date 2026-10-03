import AppKit

/// Persists a window's frame in UserDefaults and restores it only if it still
/// lands on a connected screen.
enum WindowMemory {
    private static func key(_ name: String) -> String { "windowFrame.\(name)" }

    /// Pure: returns `saved` shrunk to fit and shifted fully inside the screen it overlaps most,
    /// or nil when it overlaps no screen meaningfully (e.g. the display was unplugged).
    static func onScreenFrame(_ saved: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        var screen: CGRect?
        var bestArea: CGFloat = 0
        for v in visibleFrames {
            let i = v.intersection(saved)
            let area: CGFloat = i.isNull ? 0 : i.width * i.height
            if !i.isNull, i.width >= 100, i.height >= 50, area > bestArea { screen = v; bestArea = area }
        }
        guard let screen else { return nil }
        var f = saved
        f.size.width = min(f.width, screen.width)
        f.size.height = min(f.height, screen.height)
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - f.height)
        return f
    }

    /// Restore (if a valid saved frame exists) and start saving on move/resize.
    /// `restoreSize: false` restores position only (fixed-size windows).
    /// `contentAspect` keeps the restored content area at that ratio (top edge stays put).
    static func attach(to window: NSWindow, name: String, restoreSize: Bool, contentAspect: CGFloat? = nil) {
        let d = UserDefaults.standard
        if let s = d.string(forKey: key(name)) {
            var saved = NSRectFromString(s)
            if !restoreSize { saved.size = window.frame.size }
            if saved.width > 0, var f = onScreenFrame(saved, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
                if let aspect = contentAspect {
                    let c = window.contentRect(forFrameRect: f)
                    let fixed = window.frameRect(forContentRect: NSRect(origin: c.origin, size: NSSize(width: c.width, height: (c.width / aspect).rounded())))
                    f = NSRect(x: f.minX, y: f.maxY - fixed.height, width: fixed.width, height: fixed.height)
                }
                window.setFrame(f, display: false)
            }
        }
        let save: (Notification) -> Void = { [weak window] _ in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            d.set(NSStringFromRect(window.frame), forKey: key(name))
        }
        for n in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: n, object: window, queue: .main, using: save)
        }
    }
}
