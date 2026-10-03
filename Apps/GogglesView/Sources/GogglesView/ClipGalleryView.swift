import AppKit
import SwiftUI

struct ClipGalleryView: View {
    @StateObject private var model = ClipLibraryModel()
    @State private var trimming: Clip?

    var body: some View {
        Group {
            if model.clips.isEmpty {
                Text("No recordings in \(RecordingPrefs.directory.path)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(model.clips) { clip in
                            ClipCell(clip: clip, onTrim: { trimming = clip }, onTrash: { model.trash(clip) })
                                .onAppear { model.loadMediaIfNeeded(clip) }
                        }
                    }.padding(12)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar { Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh") }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }
        .sheet(item: $trimming, onDismiss: { model.reload() }) { clip in
            TrimView(clip: clip) { trimming = nil }
        }
    }
}

private struct ClipCell: View {
    let clip: Clip
    let onTrim: () -> Void
    let onTrash: () -> Void
    @State private var anchor: NSView?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black.opacity(0.15)
                if let t = clip.thumbnail { Image(nsImage: t).resizable().scaledToFit() }
                else { ProgressView().controlSize(.small) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Text("\(clip.date.formatted(date: .abbreviated, time: .shortened)) · \(ClipLibrary.formatDuration(clip.duration)) · \(ClipLibrary.formatSize(clip.size))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .background(AnchorView(view: $anchor))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(clip.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(clip.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Share…") { share() }
            Button("Trim…") { onTrim() }
            Divider()
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
