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
    /// Kinds already shown since launch; the hint appears at most once per kind per launch.
    private static var shownThisLaunch = Set<Kind>()

    /// Pure, for tests: show unless the user opted out, already cropped the matching picture,
    /// or has already seen this hint during this launch.
    static func shouldShow(suppressed: Bool, cropActive: Bool, shownThisLaunch: Bool = false) -> Bool {
        !suppressed && !cropActive && !shownThisLaunch
    }

    /// Forget the per-launch memory (tests only).
    static func resetLaunchStateForTests() { shownThisLaunch = [] }

    static func text(for kind: Kind) -> (title: String, body: String, button: String) {
        switch kind {
        case .output:
            return (L("The goggles' overlay will be in your stream"),
                    L("The goggles draw their own on-screen display (flight data, battery, storage warnings) into the picture they send, so it appears in OBS, recordings and streams too.\n\nYou can turn it off on the goggles, or crop it out here with Output framing. That crop only affects what you record and stream; the preview stays as it is.\n\nTip: to crop the picture later but keep the overlay's data in the original, set the goggles' display scale to about 70%. The picture then sits inside the frame and a centred crop of about 1.4x (Output framing zoom, or your editor) removes the overlay."),
                    L("Open output framing"))
        case .captureWindow:
            return (L("The goggles' overlay will be in your capture"),
                    L("The goggles draw their own on-screen display (flight data, battery, storage warnings) into the picture they send, so a Window Capture of this window shows it too.\n\nYou can turn it off on the goggles, or zoom or crop it out with Framing, which also applies to this window.\n\nTip: set the goggles' display scale to about 70% and zoom this window to about 1.4x to hide the overlay while the goggles still send it."),
                    L("Open framing"))
        }
    }

    static func noteStarted(_ kind: Kind) {
        let d = UserDefaults.standard
        let crop: Bool
        switch kind {
        case .output: crop = OutputFramingPrefs.enabled
        case .captureWindow: crop = FramingPrefs.zoom > 1 || FramingPrefs.aspect.ratio != nil
        }
        guard shouldShow(suppressed: d.bool(forKey: suppressKey), cropActive: crop,
                         shownThisLaunch: shownThisLaunch.contains(kind)) else { return }
        shownThisLaunch.insert(kind)
        DispatchQueue.main.async {
            guard !showing else { return }
            showing = true
            defer { showing = false }
            let t = text(for: kind)
            let alert = NSAlert()
            alert.messageText = t.title
            alert.informativeText = t.body
            alert.addButton(withTitle: t.button)
            alert.addButton(withTitle: L("Not now"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("Don't show this again")
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
