import Foundation

enum ClipSort: String, CaseIterable, Identifiable {
    case newest, oldest, longest, largest, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: L("Newest first")
        case .oldest: L("Oldest first")
        case .longest: L("Longest first")
        case .largest: L("Largest first")
        case .name: L("Name")
        }
    }
}

enum ClipDateFilter: Equatable {
    case any, today, last7Days, last30Days
    /// Inclusive days (the time of day of either end is ignored).
    case custom(ClosedRange<Date>)

    var title: String {
        switch self {
        case .any: L("Any date")
        case .today: L("Today")
        case .last7Days: L("Last 7 days")
        case .last30Days: L("Last 30 days")
        case .custom(let r): L("%@ to %@", r.lowerBound.formatted(date: .abbreviated, time: .omitted), r.upperBound.formatted(date: .abbreviated, time: .omitted))
        }
    }

    func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .any: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .last7Days: return date >= now.addingTimeInterval(-7 * 86_400) && date <= now
        case .last30Days: return date >= now.addingTimeInterval(-30 * 86_400) && date <= now
        case .custom(let r):
            let lo = calendar.startOfDay(for: r.lowerBound)
            guard let hi = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: r.upperBound)) else { return false }
            return date >= lo && date < hi
        }
    }
}

enum ClipTagMatch: String, CaseIterable, Identifiable {
    case any, all
    var id: String { rawValue }
    var title: String { self == .any ? L("Any selected tag") : L("All selected tags") }
}

struct ClipFilter: Equatable {
    var text = ""
    /// Tag display names; compared by `ClipMetadata.tagKey`.
    var tags: [String] = []
    var tagMatch: ClipTagMatch = .any
    var date: ClipDateFilter = .any
    /// `ClipGoggles.key` of the chosen goggles; `ClipGoggles.unknownKey` for clips without record info; nil = all.
    var goggles: String?
    var favouritesOnly = false
    var sort: ClipSort = .newest

    /// Sort is a view setting, not a filter.
    var isActive: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !tags.isEmpty || date != .any || goggles != nil || favouritesOnly
    }

    mutating func clear() { let s = sort; self = ClipFilter(); sort = s }
}

enum ClipGoggles {
    static let unknownKey = ""

    struct Option: Equatable, Identifiable { let key: String; let label: String; var id: String { key } }

    static func key(_ m: ClipMetadata?) -> String {
        if let s = m?.gogglesSerial, !s.isEmpty { return s }
        if let n = m?.gogglesName, !n.isEmpty { return n }
        return unknownKey
    }

    static func label(_ m: ClipMetadata?) -> String? {
        if let n = m?.gogglesName, !n.isEmpty { return n }
        if let s = m?.gogglesSerial, !s.isEmpty { return L("Serial %@", s) }
        return nil
    }
}

/// Pure filtering, sorting and facet counting over the clip list.
enum ClipIndex {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every whitespace-separated word must appear in the name, note, a tag or the goggles name/serial.
    static func matchesText(_ clip: Clip, _ query: String) -> Bool {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let m = clip.metadata
        let hay = fold(([clip.name, m?.note ?? "", m?.gogglesName ?? "", m?.gogglesSerial ?? ""] + (m?.tags ?? [])).joined(separator: "\n"))
        return words.allSatisfy { hay.contains($0) }
    }

    static func matchesTags(_ clip: Clip, _ wanted: [String], mode: ClipTagMatch) -> Bool {
        guard !wanted.isEmpty else { return true }
        let have = Set((clip.metadata?.tags ?? []).map(ClipMetadata.tagKey))
        let want = wanted.map(ClipMetadata.tagKey)
        return mode == .any ? want.contains(where: have.contains) : want.allSatisfy(have.contains)
    }

    static func apply(_ f: ClipFilter, to clips: [Clip], now: Date = Date(), calendar: Calendar = .current) -> [Clip] {
        let kept = clips.filter { c in
            (!f.favouritesOnly || c.metadata?.favourite == true)
                && f.date.contains(c.date, now: now, calendar: calendar)
                && (f.goggles == nil || ClipGoggles.key(c.metadata) == f.goggles)
                && matchesTags(c, f.tags, mode: f.tagMatch)
                && matchesText(c, f.text)
        }
        return sorted(kept, by: f.sort)
    }

    static func sorted(_ clips: [Clip], by sort: ClipSort) -> [Clip] {
        func byName(_ a: Clip, _ b: Clip) -> Bool {
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.url.path < b.url.path : r == .orderedAscending
        }
        switch sort {
        case .newest: return clips.sorted { $0.date != $1.date ? $0.date > $1.date : byName($0, $1) }
        case .oldest: return clips.sorted { $0.date != $1.date ? $0.date < $1.date : byName($0, $1) }
        case .longest:
            // Unknown durations (not loaded yet) go last.
            return clips.sorted {
                let (a, b) = ($0.duration ?? -1, $1.duration ?? -1)
                return a != b ? a > b : byName($0, $1)
            }
        case .largest: return clips.sorted { $0.size != $1.size ? $0.size > $1.size : byName($0, $1) }
        case .name: return clips.sorted(by: byName)
        }
    }

    /// Distinct tags with clip counts, most used first then alphabetical. Spelling of the first occurrence wins.
    static func allTags(_ clips: [Clip]) -> [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for c in clips { for t in c.metadata?.tags ?? [] {
            let k = ClipMetadata.tagKey(t)
            counts[k] = (counts[k]?.tag ?? t, (counts[k]?.count ?? 0) + 1)
        } }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
            .map { (tag: $0.tag, count: $0.count) }
    }

    /// Known goggles by name, with an "Unknown" entry last when some clips have no record info.
    static func knownGoggles(_ clips: [Clip]) -> [ClipGoggles.Option] {
        var byKey: [String: String] = [:]
        var hasUnknown = false
        for c in clips {
            let k = ClipGoggles.key(c.metadata)
            if k == ClipGoggles.unknownKey { hasUnknown = true } else if byKey[k] == nil { byKey[k] = ClipGoggles.label(c.metadata) ?? k }
        }
        var out = byKey.map { ClipGoggles.Option(key: $0.key, label: $0.value) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        if hasUnknown && !out.isEmpty { out.append(.init(key: ClipGoggles.unknownKey, label: L("Unknown goggles"))) }
        return out
    }

    static func countLabel(shown: Int, total: Int) -> String {
        if shown == total { return total == 1 ? L("%lld clip", total) : L("%lld clips", total) }
        return total == 1 ? L("%lld of %lld clip", shown, total) : L("%lld of %lld clips", shown, total)
    }

    /// Shift-click: the visible urls between `anchor` and `target`, inclusive. Falls back to just the target.
    static func range(from anchor: URL?, to target: URL, in visible: [Clip]) -> [URL] {
        guard let anchor, let a = visible.firstIndex(where: { $0.url == anchor }),
              let b = visible.firstIndex(where: { $0.url == target }) else { return [target] }
        return visible[min(a, b)...max(a, b)].map(\.url)
    }
}
