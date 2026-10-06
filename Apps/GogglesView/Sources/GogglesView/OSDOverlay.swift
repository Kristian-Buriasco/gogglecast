#if canImport(AppKit)
import SwiftUI
import GogglesXPC

enum OSDPrefs {
    static let enabledKey = "osdEnabled"
    static let showFpsKey = "osdShowFps"
    static let showBitrateKey = "osdShowBitrate"
    static let showResolutionKey = "osdShowResolution"
    static let showDropsKey = "osdShowDrops"
    static let showLatencyKey = "osdShowLatency"
    static let showBatteryKey = "osdShowBattery"
}

/// Stats overlay drawn over the video in the main window only (never the
/// capture window, which must stay clean for OBS).
struct OSDOverlay: View {
    let stats: StreamStats?
    var resolution: String?
    var latencyMs: Double?
    var batteryPercent: Int?

    @AppStorage(OSDPrefs.enabledKey) private var enabled = false
    @AppStorage(RaceModePrefs.key) private var race = false
    @AppStorage(OSDPrefs.showFpsKey) private var showFps = true
    @AppStorage(OSDPrefs.showBitrateKey) private var showBitrate = true
    @AppStorage(OSDPrefs.showResolutionKey) private var showResolution = true
    @AppStorage(OSDPrefs.showDropsKey) private var showDrops = false
    @AppStorage(OSDPrefs.showLatencyKey) private var showLatency = true
    @AppStorage(OSDPrefs.showBatteryKey) private var showBattery = true

    static func lines(
        stats: StreamStats, resolution: String?, fps: Bool, bitrate: Bool, showResolution: Bool, drops: Bool,
        latencyMs: Double? = nil, showLatency: Bool = false,
        batteryPercent: Int? = nil, showBattery: Bool = false
    ) -> [String] {
        var out: [String] = []
        if showResolution, let resolution { out.append(resolution) }
        if fps { out.append("\(stats.fps) fps") }
        if bitrate { out.append(String(format: "%.1f Mbps", stats.bitrateKbps / 1000)) }
        if showLatency, let latencyMs { out.append(String(format: "%.0f ms", latencyMs)) }
        if drops { out.append("\(stats.cumulativeDrops) dropped") }
        if showBattery, let batteryPercent { out.append("Goggles \(batteryPercent)%") }
        return out
    }

    var body: some View {
        if enabled, !race, let stats {
            let lines = Self.lines(stats: stats, resolution: resolution, fps: showFps, bitrate: showBitrate,
                                   showResolution: showResolution, drops: showDrops,
                                   latencyMs: latencyMs, showLatency: showLatency,
                                   batteryPercent: batteryPercent, showBattery: showBattery)
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
