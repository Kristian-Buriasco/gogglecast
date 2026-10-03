import AVFoundation
import AppKit

struct ClipMarker: Codable, Equatable {
    var t: Double
    var label: String
}

struct Clip: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    var duration: Double?
    var thumbnail: NSImage?
    var markers: [ClipMarker] = []
    var id: URL { url }
    var name: String { url.lastPathComponent }
    static func == (a: Clip, b: Clip) -> Bool { a.url == b.url && a.duration == b.duration && a.thumbnail === b.thumbnail }
}

enum ClipLibrary {
    static let extensions: Set<String> = ["mov", "mp4"]

    // MARK: pure helpers

    static func sortedNewestFirst(_ clips: [Clip]) -> [Clip] {
        clips.sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `m:ss`, or `h:mm:ss` from an hour up. Nil/invalid -> "--:--".
    static func formatDuration(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s.rounded())
        let (h, m, sec) = (t / 3600, t % 3600 / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Tolerant: bad/absent data -> []. Sorted by time, negatives and non-finite dropped.
    static func decodeMarkers(_ data: Data?) -> [ClipMarker] {
        guard let data, let m = try? JSONDecoder().decode([ClipMarker].self, from: data) else { return [] }
        return m.filter { $0.t.isFinite && $0.t >= 0 }.sorted { $0.t < $1.t }
    }

    static func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension("markers.json")
    }

    /// `<name>-trim.<ext>`, then `-trim-2`, `-trim-3`... never an existing path.
    static func trimOutputURL(for url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while true {
            let cand = dir.appendingPathComponent(n == 1 ? "\(base)-trim.\(ext)" : "\(base)-trim-\(n).\(ext)")
            if !exists(cand) { return cand }
            n += 1
        }
    }

    // MARK: scanning

    /// Synchronous, cheap metadata only (no AVFoundation).
    static func scan(_ dir: URL = RecordingPrefs.directory) -> [Clip] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let clips: [Clip] = urls.compactMap { u in
            guard extensions.contains(u.pathExtension.lowercased()),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile ?? true else { return nil }
            return Clip(url: u, date: v.creationDate ?? v.contentModificationDate ?? .distantPast,
                        size: Int64(v.fileSize ?? 0),
                        markers: decodeMarkers(try? Data(contentsOf: sidecarURL(for: u))))
        }
        return sortedNewestFirst(clips)
    }

    /// Loads duration + thumbnail (~1 s in, or the midpoint for shorter clips).
    static func loadMedia(for url: URL) async -> (duration: Double?, thumbnail: NSImage?) {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration)).map { $0.seconds }.flatMap { $0.isFinite ? $0 : nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        let at = CMTime(seconds: min(1, (dur ?? 2) / 2), preferredTimescale: 600)
        let img = (try? await gen.image(at: at).image).map { NSImage(cgImage: $0, size: .zero) }
        return (dur, img)
    }
}

@MainActor
final class ClipLibraryModel: ObservableObject {
    @Published var clips: [Clip] = []
    private var loading = Set<URL>()

    func reload() {
        let old = Dictionary(uniqueKeysWithValues: clips.map { ($0.url, $0) })
        clips = ClipLibrary.scan().map { c in
            var c = c
            if let o = old[c.url], o.size == c.size { c.duration = o.duration; c.thumbnail = o.thumbnail }
            return c
        }
    }

    func loadMediaIfNeeded(_ clip: Clip) {
        guard clip.thumbnail == nil, !loading.contains(clip.url) else { return }
        loading.insert(clip.url)
        Task {
            let m = await ClipLibrary.loadMedia(for: clip.url)
            loading.remove(clip.url)
            if let i = clips.firstIndex(where: { $0.url == clip.url }) {
                clips[i].duration = m.duration
                clips[i].thumbnail = m.thumbnail ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            }
        }
    }

    func trash(_ clip: Clip) {
        try? FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: ClipLibrary.sidecarURL(for: clip.url), resultingItemURL: nil)
        reload()
    }
}
