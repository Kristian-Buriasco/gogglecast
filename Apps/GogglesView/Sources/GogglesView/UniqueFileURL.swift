import Foundation

/// Output file names are second-resolution timestamps, so two goggles windows
/// recording/screenshotting in the same second would collide (AVAssetWriter
/// refuses an existing file; a PNG would be overwritten). `reserve` hands out
/// "name.mov", "name-2.mov", ... and remembers names it already gave out, since
/// writers create their files asynchronously.
enum UniqueFileURL {
    private static let lock = NSLock()
    private static var reserved: Set<String> = []

    /// Pure core: first of `url`, `url-2`, `url-3`, ... for which `isTaken` is false.
    static func firstFree(_ url: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(url) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        var n = 2
        while true {
            var candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    static func reserve(_ url: URL, fileManager: FileManager = .default) -> URL {
        lock.lock(); defer { lock.unlock() }
        let chosen = firstFree(url) { reserved.contains($0.path) || fileManager.fileExists(atPath: $0.path) }
        reserved.insert(chosen.path)
        return chosen
    }
}
