import Foundation

#if canImport(SwiftUI)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────
// GUI restyle task (post-Phase-3 v1 skin pass, bounded/approved in chat --
// see .superpowers/sdd/plan/task-gui-restyle-brief.md): shared presentational
// pieces for the CosmoViewer-Direct-inspired chrome -- the warm red/orange
// top/bottom edge glow, the in-window status pill (reusing Task 3.6's
// `GogglesStatusGlyphCategory`), and the version-footer text. Deliberately
// small and dumb: no state, no XPC, nothing here changes app behavior.
//
// This is a pure skin pass -- nothing in this file touches
// `GogglesConnectionCoordinator`/`DecodeSession`/`HelperClient` or anything
// under `Helper/GogglesHelper/`/`Packages/`.
// ─────────────────────────────────────────────────────────────────────────

enum AppChrome {
    /// A dark, near-black main content background -- the task brief's
    /// description of the CosmoViewer Direct reference ("dark, near-black
    /// main content background"). Deliberately a fixed color, not
    /// system-light/dark-adaptive: this is a chosen brand-style dark chrome
    /// matching the reference, the same way the reference itself doesn't
    /// switch to a light theme.
    static let backgroundColor = Color(red: 0.06, green: 0.06, blue: 0.07)

    /// The warm red-to-orange gradient stops used by both edge glow strips
    /// (`AppGlowStrip`) -- named here once so the top and bottom strips
    /// can't drift out of sync.
    static let glowColors: [Color] = [
        Color(red: 0.92, green: 0.20, blue: 0.05),
        Color(red: 1.00, green: 0.58, blue: 0.14),
        Color(red: 0.92, green: 0.20, blue: 0.05),
    ]

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

/// The warm red/orange ambient-glow edge strip (task brief point 1): "a
/// warm red-to-orange horizontal gradient glow strip along the very top
/// edge ... and a matching one along the very bottom edge ... like a soft
/// accent light, not a solid color bar." Implemented as a fixed-height
/// gradient band whose opacity fades from solid at the window's outer edge
/// to fully transparent toward the content -- the "soft glow, not a loud
/// banner" effect -- via an alpha mask rather than `.blur`, so it never
/// bleeds an unpredictable amount into the content below/above it.
/// Non-interactive (`allowsHitTesting(false)`) so it never steals clicks
/// from the traffic-light buttons, the status pill, or the footer.
struct AppGlowStrip: View {
    enum Edge { case top, bottom }
    let edge: Edge

    var body: some View {
        LinearGradient(colors: AppChrome.glowColors, startPoint: .leading, endPoint: .trailing)
            .frame(height: 28)
            .mask(
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: edge == .top ? .top : .bottom,
                    endPoint: edge == .top ? .bottom : .top
                )
            )
            .opacity(0.85)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusPill")
    }
}
#endif
