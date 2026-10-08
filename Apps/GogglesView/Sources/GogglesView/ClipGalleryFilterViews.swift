import SwiftUI

/// Search field, filter menus and sort menu for the clip gallery.
struct ClipFilterBar: View {
    @Binding var filter: ClipFilter
    let tags: [(tag: String, count: Int)]
    let goggles: [ClipGoggles.Option]
    let shown: Int
    let total: Int
    @FocusState.Binding var searchFocused: Bool
    @State private var customRange = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search name, note, tag or goggles", text: $filter.text)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search clips")
                    .accessibilityIdentifier("clipSearchField")
                if !filter.text.isEmpty {
                    Button { filter.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 8) {
                dateMenu
                if !goggles.isEmpty { gogglesMenu }
                tagsMenu
                Toggle(isOn: $filter.favouritesOnly) { Image(systemName: filter.favouritesOnly ? "star.fill" : "star") }
                    .toggleStyle(.button)
                    .help("Favourites only")
                    .accessibilityLabel("Favourites only")
                    .accessibilityValue(AccessibilityLabels.onOff(filter.favouritesOnly))
                Spacer(minLength: 8)
                if filter.isActive {
                    Button("Clear filters") { filter.clear() }
                        .accessibilityLabel("Clear all filters")
                }
                sortMenu
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                ForEach(filter.tags, id: \.self) { t in
                    TagChip(text: t, removable: true) { filter.tags.removeAll { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t) } }
                }
                Spacer()
                Text(ClipIndex.countLabel(shown: shown, total: total))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(ClipIndex.countLabel(shown: shown, total: total))
                    .accessibilityIdentifier("clipCountLabel")
            }
        }
    }

    private var dateMenu: some View {
        Menu {
            Button("Any date") { filter.date = .any }
            Button("Today") { filter.date = .today }
            Button("Last 7 days") { filter.date = .last7Days }
            Button("Last 30 days") { filter.date = .last30Days }
            Divider()
            Button("Custom range…") { customRange = true }
        } label: {
            Label(filter.date.title, systemImage: "calendar")
        }
        .menuStyle(.button).fixedSize()
        .tint(filter.date == .any ? nil : .accentColor)
        .accessibilityLabel("Filter by date")
        .accessibilityValue(filter.date.title)
        .popover(isPresented: $customRange) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { customRange = false }
                    Button("Apply") {
                        filter.date = .custom(min(from, to)...max(from, to)); customRange = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(14).frame(width: 240)
        }
    }

    private var gogglesMenu: some View {
        let title = goggles.first { $0.key == filter.goggles }?.label ?? L("All goggles")
        return Menu {
            Button("All goggles") { filter.goggles = nil }
            Divider()
            ForEach(goggles) { g in
                Button { filter.goggles = g.key } label: {
                    if filter.goggles == g.key { Label(g.label, systemImage: "checkmark") } else { Text(g.label) }
                }
            }
        } label: { Label(title, systemImage: "visionpro") }
        .menuStyle(.button).fixedSize()
        .tint(filter.goggles == nil ? nil : .accentColor)
        .accessibilityLabel("Filter by goggles")
        .accessibilityValue(title)
    }

    private var tagsMenu: some View {
        Menu {
            if tags.isEmpty { Text("No tags yet") }
            ForEach(tags, id: \.tag) { t in
                let on = filter.tags.contains { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t.tag) }
                Button {
                    if on { filter.tags.removeAll { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t.tag) } } else { filter.tags.append(t.tag) }
                } label: {
                    if on { Label { Text(verbatim: "\(t.tag) (\(t.count))") } icon: { Image(systemName: "checkmark") } } else { Text(verbatim: "\(t.tag) (\(t.count))") }
                }
            }
            if !tags.isEmpty {
                Divider()
                Picker("Match", selection: $filter.tagMatch) {
                    ForEach(ClipTagMatch.allCases) { Text($0.title).tag($0) }
                }
                if !filter.tags.isEmpty { Button("Clear tags") { filter.tags = [] } }
            }
        } label: {
            Label(filter.tags.isEmpty ? L("Tags") : L("Tags (%lld)", filter.tags.count), systemImage: "tag")
        }
        .menuStyle(.button).fixedSize()
        .tint(filter.tags.isEmpty ? nil : .accentColor)
        .accessibilityLabel("Filter by tags")
        .accessibilityValue(filter.tags.isEmpty ? L("None selected") : filter.tags.joined(separator: ", "))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $filter.sort) {
                ForEach(ClipSort.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
        } label: { Label(filter.sort.title, systemImage: "arrow.up.arrow.down") }
        .menuStyle(.button).fixedSize()
        .accessibilityLabel("Sort clips")
        .accessibilityValue(filter.sort.title)
    }
}

struct TagChip: View {
    let text: String
    var removable = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(text).lineLimit(1)
            if removable {
                Button { onRemove?() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove tag %@", text))
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        .accessibilityElement(children: removable ? .contain : .ignore)
        .accessibilityLabel(removable ? "" : L("Tag %@", text))
    }
}

/// Text field that adds tags on return/comma and suggests existing ones.
struct TagEntryField: View {
    let existing: [(tag: String, count: Int)]
    let current: [String]
    let onAdd: ([String]) -> Void
    @State private var text = ""

    private var suggestions: [String] {
        let q = ClipIndex.fold(text.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        let have = Set(current.map(ClipMetadata.tagKey))
        return existing.map(\.tag)
            .filter { !have.contains(ClipMetadata.tagKey($0)) && ClipIndex.fold($0).contains(q) }
            .prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .onChange(of: text) { _, v in if v.contains(",") { commit() } }
                .accessibilityLabel("Add tag")
                .accessibilityHint("Press return to add. Existing tags are suggested below")
            ForEach(suggestions, id: \.self) { s in
                Button { onAdd([s]); text = "" } label: {
                    Label(s, systemImage: "tag").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(L("Add existing tag %@", s))
            }
        }
    }

    private func commit() {
        let tags = ClipMetadata.parseTags(text)
        text = ""
        if !tags.isEmpty { onAdd(tags) }
    }
}

/// Tags, note and favourite for one clip.
struct ClipDetailPopover: View {
    let clip: Clip
    let allTags: [(tag: String, count: Int)]
    let onChange: ((inout ClipMetadata) -> Void) -> Void
    @State private var note: String

    init(clip: Clip, allTags: [(tag: String, count: Int)], onChange: @escaping ((inout ClipMetadata) -> Void) -> Void) {
        self.clip = clip; self.allTags = allTags; self.onChange = onChange
        _note = State(initialValue: clip.metadata?.note ?? "")
    }

    private var tags: [String] { clip.metadata?.tags ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(clip.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle(isOn: Binding(get: { clip.metadata?.favourite ?? false }, set: { v in onChange { $0.favourite = v } })) {
                    Image(systemName: clip.metadata?.favourite == true ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Favourite")
                .accessibilityValue(AccessibilityLabels.onOff(clip.metadata?.favourite ?? false))
            }
            if let g = ClipGoggles.label(clip.metadata) {
                Text(g + (clip.metadata?.width.map { w in clip.metadata?.height.map { " · \(w)x\($0)" } ?? "" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tags.isEmpty {
                FlowTags(tags: tags) { t in onChange { $0 = $0.applying(remove: [t]) } }
            }
            TagEntryField(existing: allTags, current: tags) { new in onChange { $0 = $0.applying(add: new) } }
            Text("Note").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $note)
                .font(.callout)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
                .accessibilityLabel("Note")
                .onChange(of: note) { _, v in onChange { $0.note = v } }
        }
        .padding(14).frame(width: 300)
    }
}

/// Wrapping row of removable tag chips.
struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { t in TagChip(text: t, removable: true) { onRemove(t) } }
        }
    }
}

/// Add and remove tags on every selected clip.
struct BulkTagSheet: View {
    let clips: [Clip]
    let allTags: [(tag: String, count: Int)]
    let onApply: (_ add: [String], _ remove: [String]) -> Void
    let onCancel: () -> Void
    @State private var add: [String] = []
    @State private var remove: [String] = []

    private var present: [(tag: String, count: Int)] {
        ClipIndex.allTags(clips)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(clips.count == 1 ? L("Tag 1 clip") : L("Tag %lld clips", clips.count)).font(.headline)
            Text("Add").font(.caption).foregroundStyle(.secondary)
            TagEntryField(existing: allTags, current: add) { add = ClipMetadata.normalizedTags(add + $0) }
            if !add.isEmpty { FlowTags(tags: add) { t in add.removeAll { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t) } } }
            if !present.isEmpty {
                Text("Remove (click a tag to mark it)").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(present, id: \.tag) { t in
                        let marked = remove.contains { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t.tag) }
                        Button {
                            if marked { remove.removeAll { ClipMetadata.tagKey($0) == ClipMetadata.tagKey(t.tag) } } else { remove.append(t.tag) }
                        } label: {
                            Text(verbatim: "\(t.tag) (\(t.count))").font(.caption).strikethrough(marked)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(marked ? Color.red.opacity(0.25) : Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("%@, on %lld selected clips", t.tag, t.count))
                        .accessibilityValue(marked ? L("Will be removed") : L("Kept"))
                        .accessibilityHint("Toggles removal")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(add, remove) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(add.isEmpty && remove.isEmpty)
            }
        }
        .padding(16).frame(width: 380)
    }
}
