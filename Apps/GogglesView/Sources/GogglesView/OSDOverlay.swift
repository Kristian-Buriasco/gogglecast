#if canImport(AppKit)
import SwiftUI
import GogglesXPC

enum OSDPrefs {
    static let enabledKey = "osdEnabled"
    static let showFpsKey = "osdShowFps"
    static let showBitrateKey = "osdShowBitrate"
    static let showResolutionKey = "osdShowResolution"
    static let showDropsKey = "osdShowDrops"
}

/// Stats overlay drawn over the video in the main window only (never the
/// capture window, which must stay clean for OBS).
struct OSDOverlay: View {
    let stats: StreamStats?
    var resolution: String?

    @AppStorage(OSDPrefs.enabledKey) private var enabled = false
    @AppStorage(OSDPrefs.showFpsKey) private var showFps = true
    @AppStorage(OSDPrefs.showBitrateKey) private var showBitrate = true
    @AppStorage(OSDPrefs.showResolutionKey) private var showResolution = true
    @AppStorage(OSDPrefs.showDropsKey) private var showDrops = false

    static func lines(
        stats: StreamStats, resolution: String?, fps: Bool, bitrate: Bool, showResolution: Bool, drops: Bool
    ) -> [String] {
        var out: [String] = []
        if showResolution, let resolution { out.append(resolution) }
        if fps { out.append("\(stats.fps) fps") }
        if bitrate { out.append(String(format: "%.1f Mbps", stats.bitrateKbps / 1000)) }
        if drops { out.append("\(stats.cumulativeDrops) dropped") }
        return out
    }

    var body: some View {
        if enabled, let stats {
            let lines = Self.lines(stats: stats, resolution: resolution, fps: showFps, bitrate: showBitrate,
                                   showResolution: showResolution, drops: showDrops)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
                .allowsHitTesting(false)
            }
        }
    }
}
#endif
