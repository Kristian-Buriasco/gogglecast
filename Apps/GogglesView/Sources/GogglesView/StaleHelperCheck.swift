import Foundation
import Darwin

/// After the app bundle is replaced (a DMG drag, `brew upgrade`, a manual copy or the in-app updater) the old
/// helper process keeps running the old code until something restarts it. The in-app updater already does; the
/// other routes did not, and the user had to run `launchctl kickstart` by hand. This finds that case at launch:
/// the helper process started before the helper file in the bundle was installed.
enum StaleHelperCheck {
    /// Pure and testable. `slack` covers clock rounding between the file system and the process table.
    static func isStale(processStart: Date?, binaryInstalled: Date?, slack: TimeInterval = 2) -> Bool {
        guard let processStart, let binaryInstalled else { return false }
        return processStart.addingTimeInterval(slack) < binaryInstalled
    }

    /// Start time of the newest running process named `name`, or nil if none runs. Uses the kernel process table,
    /// which lists root processes (the helper daemon) too; `proc_name` returns nothing for them.
    static func runningHelperStart(name: String = "GogglesHelper") -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        var bytes = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &bytes, nil, 0) == 0 else { return nil }
        var newest: Date?
        for p in procs.prefix(bytes / MemoryLayout<kinfo_proc>.stride) {
            let comm = withUnsafePointer(to: p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            guard comm == name else { continue }
            let t = p.kp_proc.p_un.__p_starttime
            let start = Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
            if newest == nil || start > newest! { newest = start }
        }
        return newest
    }

    /// When the helper file in this app bundle was created (a fresh copy gets a fresh creation time).
    static func binaryInstalled(bundle: URL = Bundle.main.bundleURL) -> Date? {
        var st = stat()
        let path = bundle.appendingPathComponent("Contents/MacOS/GogglesHelper").path
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) + TimeInterval(st.st_birthtimespec.tv_nsec) / 1e9)
    }

    static func helperIsStale() -> Bool {
        isStale(processStart: runningHelperStart(), binaryInstalled: binaryInstalled())
    }
}
