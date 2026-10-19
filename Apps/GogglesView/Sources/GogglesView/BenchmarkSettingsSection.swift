#if canImport(SwiftUI)
import SwiftUI

/// Settings > Advanced: open the benchmark / latency window.
struct BenchmarkSettingsSection: View {
    var body: some View {
        SettingsRow("Benchmark", help: "Frame pacing, latency, bitrate and CPU/memory on the live stream.",
                    info: "Frame pacing, latency from the background service to the display, bitrate and CPU/memory on the live stream.") {
            Button("Run benchmark…") { BenchmarkWindow.show() }
        }
    }
}
#endif
