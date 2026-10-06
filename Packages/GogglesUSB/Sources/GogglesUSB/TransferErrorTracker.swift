/// Counts consecutive failed bulk-IN transfer completions so a persistent
/// error (ERROR, STALL, OVERFLOW, TIMED_OUT) ends the stream instead of being
/// resubmitted in a hot loop. Pure so it can be unit tested without libusb.
struct TransferErrorTracker {
    static let defaultThreshold = 50
    let threshold: Int
    private(set) var consecutiveFailures = 0

    init(threshold: Int = TransferErrorTracker.defaultThreshold) {
        self.threshold = threshold
    }

    /// Returns true once `threshold` consecutive non-completed statuses have
    /// been seen. A completed transfer resets the count.
    mutating func record(completed: Bool) -> Bool {
        if completed {
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures += 1
        return consecutiveFailures >= threshold
    }
}
