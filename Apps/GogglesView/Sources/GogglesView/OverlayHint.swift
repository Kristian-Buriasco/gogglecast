#if canImport(AppKit)
import AppKit

/// The goggles draw their own on-screen display (flight data, battery, storage warnings) into the
/// picture they send, so it also lands in OBS, recordings and streams. Tell the user once, and point
/// at the crop that can remove it.
enum OverlayHint {
    enum Kind { case output, captureWindow }

    static let suppressKey = "hintGogglesOverlayHidden"
    /// Opens Settings; wired in `main.swift`.
    static var openSettings: (() -> Void)?
    private static var showing = false

    /// Pure, for tests: show unless the user opted out or already cropped the matching picture.
    static func shouldShow(suppressed: Bool, cropActive: Bool) -> Bool { !suppressed && !cropActive }

    static func text(for kind: Kind) -> (title: String, body: String, button: String) {
        switch kind {
        case .output:
            return ("The goggles' overlay will be in your stream",
                    "The goggles draw their own on-screen display (flight data, battery, storage warnings) into the picture they send, so it appears in OBS, recordings and streams too.\n\nYou can turn it off on the goggles, or crop it out here with Output framing. That crop only affects what you record and stream; the preview stays as it is.",
                    "Open output framing")
        case .captureWindow:
            return ("The goggles' overlay will be in your capture",
                    "The goggles draw their own on-screen display (flight data, battery, storage warnings) into the picture they send, so a Window Capture of this window shows it too.\n\nYou can turn it off on the goggles, or zoom or crop it out with Framing, which also applies to this window.",
                    "Open framing")
        }
    }

    static func noteStarted(_ kind: Kind) {
        let d = UserDefaults.standard
        let crop: Bool
        switch kind {
        case .output: crop = OutputFramingPrefs.enabled
        case .captureWindow: crop = FramingPrefs.zoom > 1 || FramingPrefs.aspect.ratio != nil
        }
        guard shouldShow(suppressed: d.bool(forKey: suppressKey), cropActive: crop) else { return }
        DispatchQueue.main.async {
            guard !showing else { return }
            showing = true
            defer { showing = false }
            let t = text(for: kind)
            let alert = NSAlert()
            alert.messageText = t.title
            alert.informativeText = t.body
            alert.addButton(withTitle: t.button)
            alert.addButton(withTitle: "Not now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on { d.set(true, forKey: suppressKey) }
            if response == .alertFirstButtonReturn {
                d.set("Display", forKey: "settingsTab")
                openSettings?()
            }
        }
    }
}
#endif
