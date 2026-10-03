import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// GUI restyle task (post-Phase-3 v1 skin pass, bounded/approved in chat --
// see .superpowers/sdd/plan/task-gui-restyle-brief.md): shared presentational
// pieces for the CosmoViewer-Direct-inspired chrome -- the in-window status
// pill (reusing Task 3.6's `GogglesStatusGlyphCategory`) and the
// version-footer text. Deliberately small and dumb: no state, no XPC,
// nothing here changes app behavior.
//
// This is a pure skin pass -- nothing in this file touches
// `GogglesConnectionCoordinator`/`DecodeSession`/`HelperClient` or anything
// under `Helper/GogglesHelper/`/`Packages/`.
//
// task-gui-v2 follow-up (this task): the original pass also had a top/bottom
// ambient edge-glow strip (`AppGlowStrip`, gradient accent bar). Removed
// outright per live user feedback after seeing it on screen ("drop the glow
// strip entirely ... don't try to tone it down, remove it") -- not toned
// down, not made subtler, gone. See `GogglesConnectionView.swift`'s `body`,
// which no longer overlays it.
// ─────────────────────────────────────────────────────────────────────────

enum AppChrome {
    /// A dark, near-black main content background -- the task brief's
    /// description of the CosmoViewer Direct reference ("dark, near-black
    /// main content background"). Deliberately a fixed color, not
    /// system-light/dark-adaptive: this is a chosen brand-style dark chrome
    /// matching the reference, the same way the reference itself doesn't
    /// switch to a light theme.
    static let backgroundColor = Color(red: 0.06, green: 0.06, blue: 0.07)

    #if canImport(AppKit)
    /// The exact same near-black as `backgroundColor` above, as an
    /// `NSColor` -- task-gui-v2's custom title bar (`main.swift`,
    /// `applyCustomTitleBarChrome(to:)`) sets `NSWindow.backgroundColor` to
    /// this so the now-transparent titlebar region (behind the traffic-light
    /// buttons, `titlebarAppearsTransparent = true`) reads as the same
    /// continuous dark surface as the SwiftUI content below it, rather than
    /// flashing the default light `NSWindow` background color for a frame
    /// before the hosted SwiftUI view's own background paints.
    static let windowBackgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
    #endif

    /// "GogglesView, ver. X.Y (build)" -- sourced from the running bundle's
    /// own `Info.plist` (`CFBundleName`/`CFBundleShortVersionString`/
    /// `CFBundleVersion`, the same keys `Apps/GogglesView/BundleResources/
    /// Info.plist` sets) rather than a literal copy of those values that
    /// could silently drift from the real plist.
    ///
    /// Falls back to just the bundle/app name when `Bundle.main` has no
    /// version info to read -- notably true for the raw
    /// `.build/debug/GogglesView` binary (e.g. the `--force-state` visual
    /// debug harness run straight from the build directory, not from
    /// inside `GogglesView.app`), which has no embedded `Info.plist` for
    /// `Bundle.main` to find. Deliberately never invents a placeholder
    /// version number in that case -- an absent version reads as honest;
    /// a made-up one would not.
    static var versionFooterText: String {
        let info = Bundle.main.infoDictionary
        let name = (info?["CFBundleName"] as? String) ?? "GogglesView"
        guard let shortVersion = info?["CFBundleShortVersionString"] as? String, !shortVersion.isEmpty else {
            return name
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != shortVersion {
            return "\(name), ver. \(shortVersion) (\(build))"
        }
        return "\(name), ver. \(shortVersion)"
    }

    /// task-gui-v3: the height of the band the real traffic-light window
    /// buttons occupy, used to vertically center the in-window status pill
    /// (`GogglesConnectionView`'s `statusRow` overlay) against them.
    ///
    /// NOT the commonly-quoted "28pt" figure (that's an older/approximate
    /// number that does not match current macOS) -- per the task brief's
    /// instruction to check real traffic-light geometry rather than guess,
    /// this was measured directly on this machine (macOS 26 / this app's
    /// deployment target) with a throwaway `swift` script:
    /// ```
    /// let w = NSWindow(contentRect: NSRect(x:0,y:0,width:400,height:300),
    ///                   styleMask: [.titled,.closable,.resizable,.miniaturizable],
    ///                   backing: .buffered, defer: false)
    /// w.styleMask.insert(.fullSizeContentView)
    /// w.standardWindowButton(.closeButton)?.frame   // (9.0, 9.0, 14.0, 14.0)
    /// w.frame.height - w.contentLayoutRect.height   // 32.0
    /// ```
    /// The three traffic-light buttons live in a title-bar container view
    /// whose height is exactly `window.frame.height -
    /// window.contentLayoutRect.height`; that measured out to 32pt (not
    /// 28pt), with the close button's frame (y=9, height=14, so vertical
    /// center 16pt from the container's bottom == 16pt from its top of a
    /// 32pt-tall container) confirming AppKit centers the buttons in that
    /// exact 32pt band. `applyCustomTitleBarChrome` (`main.swift`) only ever
    /// changes how that existing band is *painted*
    /// (`titlebarAppearsTransparent`/`.fullSizeContentView`), never its
    /// height or the traffic lights' position within it, so this measured
    /// 32pt is still exactly where AppKit centers the three buttons in the
    /// real running app. Kept here (not hardcoded at the SwiftUI call site)
    /// so the one number the pill-alignment math depends on has one
    /// definition, next to the other window-chrome constants in this file.
    static let titleBarHeight: CGFloat = 32

    #if canImport(AppKit)
    /// Live-measured replacement for the fixed `titleBarHeight` constant
    /// above: user feedback confirmed the assumed-symmetric-centering
    /// approach (`.frame(height: titleBarHeight)`, HStack's default
    /// `.center` alignment) did NOT actually line up with the real traffic
    /// lights on screen, despite the constant's own doc comment claiming a
    /// verified measurement -- rather than re-guess a new fixed number,
    /// this reads the REAL close-button frame off the actual live window
    /// at the point it's called (after `applyCustomTitleBarChrome` has been
    /// applied), and returns twice its distance from the window's top edge.
    /// A top-pinned view given `.frame(height: this value)` then has its
    /// SwiftUI-default-centered content land exactly on the real traffic
    /// lights' vertical center, by construction, not by an assumption about
    /// AppKit's internal title-bar-container symmetry that turned out not
    /// to hold. Falls back to `titleBarHeight` if the button/window geometry
    /// isn't available for any reason (should not happen for a real,
    /// on-screen `NSWindow`, but this must never crash a production path).
    static func measuredPillBandHeight(for window: NSWindow) -> CGFloat {
        guard let closeButton = window.standardWindowButton(.closeButton) else {
            return titleBarHeight
        }
        // BUG FOUND LIVE (round 3): `closeButton.frame` is relative to its
        // IMMEDIATE SUPERVIEW (an internal titlebar container view, only a
        // few dozen points tall), not the window's own coordinate space --
        // reading `.frame.origin.y` directly against `window.frame.height`
        // (540pt for this window) produced a wildly-too-large "offset from
        // top", which is exactly why the identity/pill row rendered ~200pt
        // down the window instead of at the real top edge. Converting the
        // button's bounds to the window's base coordinate system (`nil`
        // target, standard AppKit `NSView.convert(_:to:)` idiom for "give
        // me coordinates relative to the window") fixes this properly.
        let frameInWindow = closeButton.convert(closeButton.bounds, to: nil)
        let buttonCenterYFromBottom = frameInWindow.origin.y + frameInWindow.height / 2
        let offsetFromTop = window.frame.height - buttonCenterYFromBottom
        guard offsetFromTop > 0, offsetFromTop < window.frame.height / 2 else {
            // Sanity bound: a real title-bar-band offset is small (tens of
            // points), never more than half the window -- if geometry ever
            // looks implausible (e.g. read before layout has settled),
            // fall back rather than render something worse than the fixed
            // constant.
            return titleBarHeight
        }
        return offsetFromTop * 2
    }
    #endif

    /// Status-dot color per `GogglesStatusGlyphCategory` -- the same
    /// three-bucket mapping `MenuBarController.glyphImage(for:)` uses for
    /// the real `NSStatusItem` (red/yellow/green), reused here so the
    /// in-window status pill and the menu bar glyph never disagree about
    /// what a given state's color means.
    static func dotColor(for category: GogglesStatusGlyphCategory) -> Color {
        switch category {
        case .error: return .red
        case .waiting: return .yellow
        case .live: return .green
        }
    }
}

/// The in-window equivalent of the reference's right-aligned, grouped
/// "● Goggles ⌄" / "● Video" title-bar menu items (task brief point 2) --
/// a small colored status dot (`GogglesStatusGlyphCategory`, reused
/// verbatim from Task 3.6) plus a short status label.
///
/// Deliberately a SINGLE pill, not a fabricated "Goggles" + "Video" pair:
/// the reference product visually splits device-pairing status from
/// video-stream status because it models those as two independent things,
/// but GogglesView's `GogglesUIState`/`GogglesStatusGlyphCategory` is one
/// unified 9-state pipeline (design §6) with no independently-tracked
/// "video stream health" separate from "device connection health" at the
/// UI layer. Inventing a second, parallel status bucket here just to match
/// the reference's item count would show the user state that doesn't
/// actually exist -- worse than the reference's real two-item layout, not
/// a faithful copy of it. One honest, always-accurate status pill is the
/// better skin-pass call; see task-gui-restyle-report.md for the same
/// reasoning applied to `MenuBarController`.
struct StatusPill: View {
    let category: GogglesStatusGlyphCategory
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AppChrome.dotColor(for: category))
                .frame(width: 7, height: 7)
            Text("GogglesView — \(text)")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(text)
        .accessibilityIdentifier("statusPill")
    }
}
#endif
