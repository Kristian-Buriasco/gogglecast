import Foundation

/// Per-clip user metadata (tags, note, favourite) plus record-time info, stored in a
/// `<clip basename>.gvmeta.json` sidecar next to the clip so it follows the file when moved or backed up.
struct ClipMetadata: Codable, Equatable {
    static let currentVersion = 1
    static let maxTagLength = 40

    var version: Int = ClipMetadata.currentVersion
    var tags: [String] = []
    var note: String = ""
    var favourite: Bool = false
    // Record-time info, written by the recorder when known.
    var gogglesName: String?
    var gogglesSerial: String?
    var width: Int?
    var height: Int?
    var fps: Double?

    init() {}

    /// Tolerant: every field is optional, wrong-typed fields fall back to defaults, unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? ClipMetadata.currentVersion
        tags = ClipMetadata.normalizedTags((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? [])
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        favourite = (try? c.decodeIfPresent(Bool.self, forKey: .favourite)) ?? false
        gogglesName = (try? c.decodeIfPresent(String.self, forKey: .gogglesName)) ?? nil
        gogglesSerial = (try? c.decodeIfPresent(String.self, forKey: .gogglesSerial)) ?? nil
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? nil
        fps = (try? c.decodeIfPresent(Double.self, forKey: .fps)) ?? nil
    }

    /// True when there is nothing worth keeping on disk.
    var isEmpty: Bool {
        tags.isEmpty && note.isEmpty && !favourite && gogglesName == nil && gogglesSerial == nil
            && width == nil && height == nil && fps == nil
    }

    // MARK: tags

    /// One tag: trimmed, inner whitespace collapsed, no leading `#`, capped. Empty -> nil.
    static func normalizedTag(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.count > maxTagLength { s = String(s.prefix(maxTagLength)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? nil : s
    }

    /// Case- and diacritic-insensitive identity of a tag.
    static func tagKey(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Normalizes each tag and drops duplicates (first spelling wins), keeping order.
    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in raw {
            guard let t = normalizedTag(r), seen.insert(tagKey(t)).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Splits "a, b; c" style input into normalized tags.
    static func parseTags(_ input: String) -> [String] {
        normalizedTags(input.split(whereSeparator: { ",;\n".contains($0) }).map(String.init))
    }

    func applying(add: [String] = [], remove: [String] = []) -> ClipMetadata {
        var m = self
        let drop = Set(remove.map(ClipMetadata.tagKey))
        m.tags = ClipMetadata.normalizedTags(tags.filter { !drop.contains(ClipMetadata.tagKey($0)) } + add)
        return m
    }

    /// Metadata for a clip trimmed out of this one: same tags, favourite and goggles, a "Trimmed from" note.
    func carriedOver(fromClipNamed name: String) -> ClipMetadata {
        var m = self
        m.note = note.isEmpty ? L("Trimmed from %@", name) : "\(note)\n" + L("Trimmed from %@", name)
        return m
    }
}

/// What the recorder knows when a recording starts.
struct ClipRecordInfo: Equatable {
    var gogglesName: String?
    var gogglesSerial: String?
    var width: Int?
    var height: Int?
    var fps: Double?
}

enum ClipMetadataStore {
    static let suffix = "gvmeta.json"

    static func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension(suffix)
    }

    /// Nil when the data is absent or unreadable.
    static func decode(_ data: Data?) -> ClipMetadata? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ClipMetadata.self, from: data)
    }

    static func encode(_ meta: ClipMetadata) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var m = meta
        m.version = ClipMetadata.currentVersion
        return try? enc.encode(m)
    }

    static func read(for clip: URL) -> ClipMetadata? {
        decode(try? Data(contentsOf: sidecarURL(for: clip)))
    }

    /// Atomic. An empty value removes the sidecar instead of leaving a blank file.
    @discardableResult
    static func write(_ meta: ClipMetadata, for clip: URL) -> Bool {
        let url = sidecarURL(for: clip)
        if meta.isEmpty { try? FileManager.default.removeItem(at: url); return true }
        guard let data = encode(meta) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Read-modify-write; a corrupt or missing sidecar starts from empty.
    @discardableResult
    static func update(for clip: URL, _ change: (inout ClipMetadata) -> Void) -> ClipMetadata {
        var m = read(for: clip) ?? ClipMetadata()
        change(&m)
        write(m, for: clip)
        return m
    }

    static func merge(_ info: ClipRecordInfo, into meta: ClipMetadata) -> ClipMetadata {
        var m = meta
        if let v = info.gogglesName, !v.isEmpty { m.gogglesName = v }
        if let v = info.gogglesSerial, !v.isEmpty { m.gogglesSerial = v }
        if let w = info.width, let h = info.height { m.width = w; m.height = h }
        if let v = info.fps { m.fps = v }
        return m
    }

    /// The single call the recorder makes when a recording starts. No-op without info; writes off the caller's queue.
    static func writeRecordInfo(_ info: ClipRecordInfo?, for clip: URL) {
        guard let info else { return }
        DispatchQueue.global(qos: .utility).async {
            update(for: clip) { $0 = merge(info, into: $0) }
        }
    }

    /// Copies tags, favourite and goggles info to a trimmed clip's sidecar, with a "Trimmed from" note.
    @discardableResult
    static func carryOver(from source: URL, to trimmed: URL) -> Bool {
        let base = read(for: source) ?? ClipMetadata()
        return write(base.carriedOver(fromClipNamed: source.lastPathComponent), for: trimmed)
    }

    /// Existing sidecars that must travel with a clip (markers, metadata).
    static func companions(of clip: URL, fileManager: FileManager = .default) -> [URL] {
        [ClipLibrary.sidecarURL(for: clip), sidecarURL(for: clip)].filter { fileManager.fileExists(atPath: $0.path) }
    }
}

extension AccessibilityLabels {
    /// "Name, Oct 5, 0:34, 12 MB, tags fpv, coast, favourite".
    static func clipCard(name: String, date: String, duration: String, size: String, tags: [String], favourite: Bool) -> String {
        var parts = [name, date, duration, size]
        if !tags.isEmpty { parts.append(L("tags %@", tags.joined(separator: ", "))) }
        if favourite { parts.append(L("favourite")) }
        return parts.joined(separator: ", ")
    }

    static func favouriteToggle(isOn: Bool) -> String { isOn ? L("Remove from favourites") : L("Add to favourites") }
}
