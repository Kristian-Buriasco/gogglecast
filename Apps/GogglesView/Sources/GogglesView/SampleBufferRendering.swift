import AVFoundation
import CoreMedia

// ─────────────────────────────────────────────────────────────────────────
// Task 3.3: the surface `DecodeSession` enqueues finished `CMSampleBuffer`s
// onto. A protocol, not a direct `AVSampleBufferDisplayLayer` dependency,
// specifically so `DecodeSessionTests` can exercise the §7 error policy
// (30-consecutive-failure teardown in particular) with a plain in-memory
// double -- driving a real `AVSampleBufferDisplayLayer` through 30
// synthetic decode failures in a unit test would mean standing up an actual
// CALayer/VideoToolbox decode pipeline off garbage bytes, which is slow,
// flaky, and not what's being tested (the *counting/teardown* logic is what
// matters here, not VideoToolbox's own error behavior).
// ─────────────────────────────────────────────────────────────────────────

/// The minimal surface `DecodeSession` needs from a sample-buffer renderer.
/// `AVSampleBufferDisplayLayer` already implements both methods with
/// matching signatures (see the `extension` below), so production code pays
/// no adapter cost.
protocol SampleBufferRendering: AnyObject {
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
}

extension AVSampleBufferDisplayLayer: SampleBufferRendering {}
