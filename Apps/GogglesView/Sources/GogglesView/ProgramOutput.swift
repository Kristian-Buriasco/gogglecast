import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Combine
#endif

// Program output: a clean, borderless, fullscreen window on a chosen display (for example the HDMI
// output going to a vision mixer, projector or TV). It shows either every open goggles feed in a
// grid (a multiview for the crew) or a single feed. Feeds get names the crew chooses ("Runner 3");
// the default names never contain a goggles serial number, so nothing private ends up on screen.
// Zebra stripes and focus peaking are never drawn here.

/// One program output: a display and what it shows.
struct ProgramOutputConfig: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    /// CGDirectDisplayID, 0 = automatic (the next free external display).
    var display: UInt32 = 0
    /// "grid" (every feed, with names) or "single" (one clean feed).
    var layout = "grid"
    /// deviceId for a single feed, "" = follow the active window.
    var feed = ""
    var showNames = true

    var isGrid: Bool { layout != "single" }
}

enum ProgramOutputPrefs {
    static let enabledKey = "programOutputEnabled"
    static let outputsKey = "programOutputList"          // JSON [ProgramOutputConfig]
    static let feedNamesKey = "programOutputFeedNames"  // [deviceId: custom name]
    static let maxOutputs = 4

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: enabledKey) }

    /// Always at least one output so the settings card has something to edit.
    static func outputs(_ d: UserDefaults = .standard) -> [ProgramOutputConfig] {
        guard let data = d.data(forKey: outputsKey),
              let list = try? JSONDecoder().decode([ProgramOutputConfig].self, from: data), !list.isEmpty
        else { return [ProgramOutputConfig()] }
        return Array(list.prefix(maxOutputs))
    }

    static func setOutputs(_ list: [ProgramOutputConfig], defaults d: UserDefaults = .standard) {
        d.set(try? JSONEncoder().encode(Array(list.prefix(maxOutputs))), forKey: outputsKey)
    }

    static func feedNames(_ d: UserDefaults = .standard) -> [String: String] { d.dictionary(forKey: feedNamesKey) as? [String: String] ?? [:] }

    static func setFeedName(_ name: String, for deviceId: String, defaults d: UserDefaults = .standard) {
        var all = feedNames(d)
        let clean = sanitizeName(name)
        if clean.isEmpty { all.removeValue(forKey: deviceId) } else { all[deviceId] = clean }
        d.set(all, forKey: feedNamesKey)
    }

    /// Names are shown on a public screen: strip control characters, trim, cap at 24 characters.
    static func sanitizeName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces).prefix(24).description
    }
}

enum ProgramLayoutMath {
    /// Columns and rows for `count` equal tiles, wider than tall like the screen.
    static func grid(count: Int) -> (cols: Int, rows: Int) {
        guard count > 1 else { return (1, 1) }
        let cols = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        return (cols, rows)
    }

    /// Frame of tile `index` inside `size`.
    static func tile(index: Int, count: Int, in size: CGSize) -> CGRect {
        let (cols, rows) = grid(count: count)
        let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
        return CGRect(x: CGFloat(index % cols) * w, y: CGFloat(index / cols) * h, width: w, height: h)
    }
}

struct ProgramScreenInfo: Equatable {
    let id: UInt32
    let name: String
    let isMain: Bool
}

enum ProgramDisplayChoice {
    /// The display for each output, in order (nil = no display, nothing is shown). An explicit choice
    /// wins when that display is connected and not already used by an earlier output. Automatic takes
    /// the next external display nobody picked, and never the main display. An unplugged choice does
    /// not jump to another display.
    static func assign(outputs: [ProgramOutputConfig], screens: [ProgramScreenInfo]) -> [UInt32?] {
        var used = Set<UInt32>()
        var result = [UInt32?](repeating: nil, count: outputs.count)
        // Explicit choices first, so an automatic output never steals a display that is picked later.
        for (i, o) in outputs.enumerated() where o.display != 0 {
            if screens.contains(where: { $0.id == o.display }), !used.contains(o.display) {
                result[i] = o.display; used.insert(o.display)
            }
        }
        let explicit = Set(outputs.map(\.display).filter { $0 != 0 })
        for (i, o) in outputs.enumerated() where o.display == 0 {
            if let free = screens.first(where: { !$0.isMain && !used.contains($0.id) && !explicit.contains($0.id) }) {
                result[i] = free.id; used.insert(free.id)
            }
        }
        return result
    }

    /// Single-output convenience (kept for the tests and simple callers).
    static func pick(preferred: UInt32, screens: [ProgramScreenInfo]) -> UInt32? {
        var o = ProgramOutputConfig(); o.display = preferred
        return assign(outputs: [o], screens: screens)[0]
    }
}

enum ProgramFeedNaming {
    /// "Feed 1", "Feed 2", ... in open order, unless the crew named the feed.
    static func names(deviceIds: [String], custom: [String: String]) -> [String] {
        deviceIds.enumerated().map { i, id in
            let c = custom[id].map(ProgramOutputPrefs.sanitizeName) ?? ""
            return c.isEmpty ? L("Feed %lld", i + 1) : c
        }
    }
}

#if canImport(SwiftUI) && canImport(AppKit)

struct ProgramFeedInfo: Identifiable, Equatable {
    let id: String   // deviceId
    let name: String
}

/// Window content that hides the mouse pointer over the picture.
private final class ProgramContainerView: NSView {
    override func resetCursorRects() {
        let blank = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
        addCursorRect(bounds, cursor: blank)
    }
}

private final class ProgramWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ProgramFeed {
    let id: String
    let name: String
    let session: DecodeSession
    let coordinator: GogglesConnectionCoordinator
}

private struct ProgramTile: View {
    let feed: ProgramFeed
    let showName: Bool
    let showSignal: Bool
    @ObservedObject var coordinator: GogglesConnectionCoordinator

    init(feed: ProgramFeed, showName: Bool, showSignal: Bool) {
        self.feed = feed; self.showName = showName; self.showSignal = showSignal
        self.coordinator = feed.coordinator
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            GogglesVideoView(session: feed.session, isSecondary: true)
            if showSignal && coordinator.uiState.kind != .live {
                Color.black.opacity(0.6)
                Text(verbatim: L("NO SIGNAL")).font(.system(size: 28, weight: .bold)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showName {
                Text(verbatim: feed.name)
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        }
        .clipped()
    }
}

private struct ProgramOutputView: View {
    let feeds: [ProgramFeed]
    let showNames: Bool
    let multiview: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(feeds.enumerated()), id: \.element.id) { i, feed in
                    let r = ProgramLayoutMath.tile(index: i, count: feeds.count, in: geo.size)
                    ProgramTile(feed: feed, showName: showNames && multiview, showSignal: multiview)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Main thread only (called from menus, SwiftUI and the main-queue registry observer).
final class ProgramOutputController: ObservableObject {
    static let shared = ProgramOutputController()

    /// Open goggles with the name each one would get; the settings card lists them.
    @Published private(set) var available: [ProgramFeedInfo] = []

    private var sessions: () -> [GogglesSession] = { [] }
    private var active: () -> GogglesSession? = { nil }
    private var windows: [String: NSWindow] = [:]   // output id -> window
    private var shownKeys: [String: String] = [:]
    private var observers: [AnyCancellable] = []
    private var pending: DispatchWorkItem?

    func install(sessions: @escaping () -> [GogglesSession], active: @escaping () -> GogglesSession?) {
        self.sessions = sessions
        self.active = active
        observers = [
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.scheduleRefresh() },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .sink { [weak self] _ in self?.scheduleRefresh() },
        ]
        refresh()
    }

    func toggle() {
        UserDefaults.standard.set(!ProgramOutputPrefs.enabled(), forKey: ProgramOutputPrefs.enabledKey)
    }

    func sessionsChanged() { scheduleRefresh() }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    static func screenInfos() -> [ProgramScreenInfo] {
        NSScreen.screens.compactMap { s in
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ProgramScreenInfo(id: id, name: s.localizedName, isMain: s == NSScreen.screens.first)
        }
    }

    private func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private func close(_ outputId: String) {
        windows[outputId]?.orderOut(nil)
        windows[outputId]?.contentView = nil  // drops the display layers
        windows[outputId] = nil
        shownKeys[outputId] = nil
    }

    func refresh() {
        let all = sessions()
        let names = ProgramFeedNaming.names(deviceIds: all.map(\.deviceId), custom: ProgramOutputPrefs.feedNames())
        let info = zip(all, names).map { ProgramFeedInfo(id: $0.deviceId, name: $1) }
        if info != available { available = info }

        let outputs = ProgramOutputPrefs.outputs()
        for id in Set(windows.keys).subtracting(outputs.map(\.id)) { close(id) }
        guard ProgramOutputPrefs.enabled() else { for id in Array(windows.keys) { close(id) }; return }

        let assigned = ProgramDisplayChoice.assign(outputs: outputs, screens: Self.screenInfos())
        let allFeeds: [ProgramFeed] = zip(all, names).map {
            ProgramFeed(id: $0.deviceId, name: $1, session: $0.decodeSession, coordinator: $0.coordinator)
        }
        for (output, displayID) in zip(outputs, assigned) {
            guard let displayID, let screen = screen(for: displayID) else { close(output.id); continue }
            var feeds = allFeeds
            if !output.isGrid {
                let chosen = output.feed.isEmpty ? active()?.deviceId : output.feed
                feeds = feeds.filter { $0.id == chosen }
            }
            let key = "\(displayID)|\(screen.frame)|\(output.layout)|\(output.showNames)|" + feeds.map { "\($0.id):\($0.name)" }.joined(separator: ",")
            guard key != shownKeys[output.id] else { continue }
            shownKeys[output.id] = key

            let host = NSHostingView(rootView: ProgramOutputView(feeds: feeds, showNames: output.showNames, multiview: output.isGrid))
            let container = ProgramContainerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)

            let w = windows[output.id] ?? ProgramWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = container
            w.setFrame(screen.frame, display: true)
            w.backgroundColor = .black
            w.hasShadow = false
            w.isOpaque = true
            w.isReleasedWhenClosed = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.title = "GogglesView Program"
            w.orderFrontRegardless()
            windows[output.id] = w
        }
    }
}

struct ProgramOutputSettingsSection: View {
    @ObservedObject private var controller = ProgramOutputController.shared
    @AppStorage(ProgramOutputPrefs.enabledKey) private var enabled = false
    @State private var outputs = ProgramOutputPrefs.outputs()
    @State private var screens = ProgramOutputController.screenInfos()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Program output (HDMI)").font(.headline)
            Toggle("Show the program outputs", isOn: $enabled)
            ForEach($outputs) { $o in
                OutputRow(output: $o, screens: screens, feeds: controller.available,
                          canRemove: outputs.count > 1) { outputs.removeAll { $0.id == o.id } }
            }
            if outputs.count < ProgramOutputPrefs.maxOutputs {
                Button("Add output") { outputs.append(ProgramOutputConfig()) }
            }
            if !controller.available.isEmpty {
                Text("Feed names").font(.subheadline).padding(.top, 4)
                ForEach(controller.available) { f in FeedNameRow(info: f) }
            }
            Text("A clean full screen picture on each chosen display, for a vision mixer, projector or TV: one output per HDMI connection. A grid shows every open goggles window and marks a feed with no signal; one feed shows just that picture. Names never include the goggles serial number. Zebra stripes and peaking are not drawn here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: outputs) { ProgramOutputPrefs.setOutputs($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ProgramOutputController.screenInfos()
        }
    }
}

private struct OutputRow: View {
    @Binding var output: ProgramOutputConfig
    let screens: [ProgramScreenInfo]
    let feeds: [ProgramFeedInfo]
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Display", selection: Binding(get: { Int(output.display) }, set: { output.display = UInt32($0) })) {
                    Text("Automatic (next external display)").tag(0)
                    ForEach(screens, id: \.id) { s in
                        Text(verbatim: s.isMain ? "\(s.name) (\(L("main display")))" : s.name).tag(Int(s.id))
                    }
                }
                if output.display != 0, screens.first(where: { Int($0.id) == Int(output.display) })?.isMain == true {
                    Text("This is your main display: the program output will cover your controls. Pick an external display unless you know what you are doing.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Show", selection: $output.layout) {
                    Text("All feeds in a grid").tag("grid")
                    Text("One feed").tag("single")
                }
                if output.isGrid {
                    Toggle("Show feed names", isOn: $output.showNames)
                } else {
                    Picker("Feed", selection: $output.feed) {
                        Text("Follow the active window").tag("")
                        ForEach(feeds) { f in Text(verbatim: f.name).tag(f.id) }
                    }
                }
                if canRemove { Button("Remove output", role: .destructive, action: remove) }
            }
            .padding(4)
        }
    }
}

private struct FeedNameRow: View {
    let info: ProgramFeedInfo
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(text: $text, prompt: Text(verbatim: info.name)) { Text("Name") }
                .onSubmit { commit() }
                .onChange(of: text) { _ in commit() }
        }
        .onAppear { text = ProgramOutputPrefs.feedNames()[info.id] ?? "" }
    }

    private func commit() {
        ProgramOutputPrefs.setFeedName(text, for: info.id)
    }
}
#endif
