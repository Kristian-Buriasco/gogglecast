import AppKit
import SwiftUI

struct ClipGalleryView: View {
    @StateObject private var model = ClipLibraryModel()
    @State private var trimming: Clip?
    @State private var filter = ClipFilter()
    @State private var selection = Set<URL>()
    @State private var anchor: URL?
    @State private var bulkTagging = false
    @State private var confirmTrash = false
    @FocusState private var searchFocused: Bool

    private var selectedClips: [Clip] { model.clips.filter { selection.contains($0.url) } }

    var body: some View {
        let shown = ClipIndex.apply(filter, to: model.clips)
        let tags = ClipIndex.allTags(model.clips)
        return Group {
            if model.clips.isEmpty {
                Text("No recordings in \(RecordingPrefs.directory.path)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ClipFilterBar(filter: $filter, tags: tags, goggles: ClipIndex.knownGoggles(model.clips),
                                  shown: shown.count, total: model.clips.count, searchFocused: $searchFocused)
                        .padding([.horizontal, .top], 12).padding(.bottom, 4)
                    if !selection.isEmpty { selectionBar }
                    if shown.isEmpty { noMatches } else { grid(shown, tags: tags) }
                }
                .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true))
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar { Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh clips") }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        .onChange(of: model.clips.map(\.url)) { _, urls in selection.formIntersection(urls) }
        .sheet(item: $trimming, onDismiss: { model.reload() }) { clip in
            TrimView(clip: clip) { trimming = nil }
        }
        .sheet(isPresented: $bulkTagging) {
            BulkTagSheet(clips: selectedClips, allTags: tags, onApply: { add, remove in
                model.updateMetadata(for: selectedClips.map(\.url)) { $0 = $0.applying(add: add, remove: remove) }
                bulkTagging = false
            }, onCancel: { bulkTagging = false })
        }
        .confirmationDialog("Move \(selection.count) clips to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(selectedClips); selection = [] }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Text("No clips match").font(.headline)
            Button("Clear filters") { filter.clear() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
            Button("Tag selected…") { bulkTagging = true }.accessibilityLabel("Tag selected clips")
            Button("Move to Trash", role: .destructive) { confirmTrash = true }.accessibilityLabel("Move selected clips to Trash")
            Button("Deselect") { selection = [] }.accessibilityLabel("Deselect all clips")
            Spacer()
        }
        .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func grid(_ shown: [Clip], tags: [(tag: String, count: Int)]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(shown) { clip in
                    ClipCell(clip: clip, selected: selection.contains(clip.url), selectedCount: selection.count, allTags: tags,
                             onClick: { click(clip, in: shown) },
                             onTrim: { trimming = clip },
                             onTrash: { model.trash(clip) },
                             onMetadata: { change in model.updateMetadata(for: [clip.url], change) },
                             onTagSelected: { bulkTagging = true },
                             onTrashSelected: { confirmTrash = true })
                        .onAppear { model.loadMediaIfNeeded(clip) }
                }
            }.padding(12)
        }
    }

    /// Plain click selects one, command toggles, shift extends from the last clicked card.
    private func click(_ clip: Clip, in shown: [Clip]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            selection.formUnion(ClipIndex.range(from: anchor, to: clip.url, in: shown))
        } else if flags.contains(.command) {
            if !selection.insert(clip.url).inserted { selection.remove(clip.url) }
            anchor = clip.url
        } else {
            selection = selection == [clip.url] ? [] : [clip.url]
            anchor = clip.url
        }
    }
}

private struct ClipCell: View {
    let clip: Clip
    let selected: Bool
    let selectedCount: Int
    let allTags: [(tag: String, count: Int)]
    let onClick: () -> Void
    let onTrim: () -> Void
    let onTrash: () -> Void
    let onMetadata: ((inout ClipMetadata) -> Void) -> Void
    let onTagSelected: () -> Void
    let onTrashSelected: () -> Void
    @State private var anchor: NSView?
    @State private var showDetail = false

    private var tags: [String] { clip.metadata?.tags ?? [] }
    private var favourite: Bool { clip.metadata?.favourite ?? false }
    private var dateText: String { clip.date.formatted(date: .abbreviated, time: .shortened) }

    private var cardLabel: String {
        AccessibilityLabels.clipCard(name: clip.name, date: dateText, duration: ClipLibrary.formatDuration(clip.duration),
                                     size: ClipLibrary.formatSize(clip.size), tags: tags, favourite: favourite)
    }

    var body: some View {
        card
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardLabel)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the recording")
            .accessibilityAction(named: "Open") { NSWorkspace.shared.open(clip.url) }
            .accessibilityAction(named: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            .accessibilityAction(named: "Share") { share() }
            .accessibilityAction(named: "Trim") { onTrim() }
            .accessibilityAction(named: AccessibilityLabels.favouriteToggle(isOn: favourite)) { onMetadata { $0.favourite.toggle() } }
            .accessibilityAction(named: "Edit tags and note") { showDetail = true }
            .accessibilityAction(named: selected ? "Deselect" : "Select") { onClick() }
            .accessibilityAction(named: "Move to Trash") { onTrash() }
            .contextMenu { menuItems }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.black.opacity(0.15)
                    if let t = clip.thumbnail { Image(nsImage: t).resizable().scaledToFit().accessibilityHidden(true) }
                    else { ProgressView().controlSize(.small) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if favourite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).shadow(radius: 2).padding(6)
                        .accessibilityHidden(true)
                }
            }
            Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Text("\(dateText) · \(ClipLibrary.formatDuration(clip.duration)) · \(ClipLibrary.formatSize(clip.size))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    if tags.count > 3 { Text("+\(tags.count - 3)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .background(AnchorView(view: $anchor))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(clip.url) }
        .onTapGesture { onClick() }
        .popover(isPresented: $showDetail) {
            ClipDetailPopover(clip: clip, allTags: allTags, onChange: onMetadata)
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open") { NSWorkspace.shared.open(clip.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
        Button("Share…") { share() }
        Button("Trim…") { onTrim() }
        Divider()
        Button(favourite ? "Remove from favourites" : "Add to favourites") { onMetadata { $0.favourite.toggle() } }
        Button("Tags and note…") { showDetail = true }
        if selected && selectedCount > 1 {
            Button("Tag selected…") { onTagSelected() }
        }
        Divider()
        if selected && selectedCount > 1 {
            Button("Move \(selectedCount) selected to Trash", role: .destructive) { onTrashSelected() }
        } else {
            Button("Move to Trash", role: .destructive) { onTrash() }
        }
    }

    private func share() {
        guard let v = anchor else { return }
        NSSharingServicePicker(items: [clip.url]).show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
    }
}

/// Captures the backing NSView so NSSharingServicePicker can anchor to the cell.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class ClipGalleryWindowController: NSObject {
    static let shared = ClipGalleryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ClipGalleryView()))
            w.title = "Clip Gallery"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Insert in GogglesConnectionView's `recordControl` HStack.
struct GalleryButton: View {
    var body: some View {
        Button { ClipGalleryWindowController.shared.show() } label: { Image(systemName: "film.stack") }
            .help("Clip gallery (⇧⌘G)")
            .accessibilityLabel("Clip gallery")
            .accessibilityIdentifier("galleryButton")
            .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}

/// Insert in the Capture tab of SettingsView.
struct GallerySettingsRow: View {
    var body: some View {
        Button("Open clip gallery") { ClipGalleryWindowController.shared.show() }
    }
}
