#if canImport(SwiftUI)
import SwiftUI

/// Settings > Advanced: open the benchmark / latency window.
struct BenchmarkSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Benchmark").font(.headline)
            HStack {
                Button("Run benchmark…") { BenchmarkWindow.show() }
                Spacer()
            }
            Text("Frame pacing, latency from the background service to the display, bitrate and CPU/memory on the live stream.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
