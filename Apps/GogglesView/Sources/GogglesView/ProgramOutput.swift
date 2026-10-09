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

enum ProgramOutputPrefs {
    static let enabledKey = "programOutputEnabled"
    static let displayKey = "programOutputDisplay"      // CGDirectDisplayID, 0 = automatic
    static let layoutKey = "programOutputLayout"        // "grid" | "single"
    static let singleKey = "programOutputSingleDevice"  // deviceId, "" = follow the active window
    static let namesKey = "programOutputShowNames"
    static let feedNamesKey = "programOutputFeedNames"  // [deviceId: custom name]

    enum Layout: String { case grid, single }

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: enabledKey) }
    static func display(_ d: UserDefaults = .standard) -> UInt32 { UInt32(clamping: d.integer(forKey: displayKey)) }
    static func layout(_ d: UserDefaults = .standard) -> Layout { Layout(rawValue: d.string(forKey: layoutKey) ?? "") ?? .grid }
    static func singleDevice(_ d: UserDefaults = .standard) -> String { d.string(forKey: singleKey) ?? "" }
    static func showNames(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: namesKey) as? Bool ?? true }
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
    /// The display to use. An explicit choice wins when that display is connected. Automatic means the
    /// first display that is not the main one, and never the only screen the operator is working on.
    static func pick(preferred: UInt32, screens: [ProgramScreenInfo]) -> UInt32? {
        if preferred != 0, screens.contains(where: { $0.id == preferred }) { return preferred }
        if preferred != 0 { return nil }  // the chosen display is unplugged: do not jump to another one
        return screens.first(where: { !$0.isMain })?.id
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
    private var window: NSWindow?
    private var shownKey = ""
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

    private func close() {
        window?.orderOut(nil)
        window?.contentView = nil  // drops the display layers
        window = nil
        shownKey = ""
    }

    func refresh() {
        let all = sessions()
        let names = ProgramFeedNaming.names(deviceIds: all.map(\.deviceId), custom: ProgramOutputPrefs.feedNames())
        let info = zip(all, names).map { ProgramFeedInfo(id: $0.deviceId, name: $1) }
        if info != available { available = info }

        guard ProgramOutputPrefs.enabled(),
              let displayID = ProgramDisplayChoice.pick(preferred: ProgramOutputPrefs.display(), screens: Self.screenInfos()),
              let screen = screen(for: displayID) else { close(); return }

        var feeds: [ProgramFeed] = zip(all, names).map {
            ProgramFeed(id: $0.deviceId, name: $1, session: $0.decodeSession, coordinator: $0.coordinator)
        }
        let layout = ProgramOutputPrefs.layout()
        if layout == .single {
            let wanted = ProgramOutputPrefs.singleDevice()
            let chosen = wanted.isEmpty ? active()?.deviceId : wanted
            feeds = feeds.filter { $0.id == chosen }
        }
        let showNames = ProgramOutputPrefs.showNames()
        let key = "\(displayID)|\(screen.frame)|\(layout.rawValue)|\(showNames)|" + feeds.map { "\($0.id):\($0.name)" }.joined(separator: ",")
        guard key != shownKey else { return }
        shownKey = key

        let host = NSHostingView(rootView: ProgramOutputView(feeds: feeds, showNames: showNames, multiview: layout == .grid))
        let container = ProgramContainerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        let w = window ?? ProgramWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        window = w
    }
}

struct ProgramOutputSettingsSection: View {
    @ObservedObject private var controller = ProgramOutputController.shared
    @AppStorage(ProgramOutputPrefs.enabledKey) private var enabled = false
    @AppStorage(ProgramOutputPrefs.displayKey) private var display = 0
    @AppStorage(ProgramOutputPrefs.layoutKey) private var layout = ProgramOutputPrefs.Layout.grid.rawValue
    @AppStorage(ProgramOutputPrefs.singleKey) private var single = ""
    @AppStorage(ProgramOutputPrefs.namesKey) private var showNames = true
    @State private var screens = ProgramOutputController.screenInfos()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Program output (HDMI)").font(.headline)
            Toggle("Show the program output", isOn: $enabled)
            Picker("Display", selection: $display) {
                Text("Automatic (first external display)").tag(0)
                ForEach(screens, id: \.id) { s in
                    Text(verbatim: s.isMain ? "\(s.name) (\(L("main display")))" : s.name).tag(Int(s.id))
                }
            }
            if display != 0, screens.first(where: { Int($0.id) == display })?.isMain == true {
                Text("This is your main display: the program output will cover your controls. Pick an external display unless you know what you are doing.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Show", selection: $layout) {
                Text("All feeds in a grid").tag(ProgramOutputPrefs.Layout.grid.rawValue)
                Text("One feed").tag(ProgramOutputPrefs.Layout.single.rawValue)
            }
            if layout == ProgramOutputPrefs.Layout.single.rawValue {
                Picker("Feed", selection: $single) {
                    Text("Follow the active window").tag("")
                    ForEach(controller.available) { f in Text(verbatim: f.name).tag(f.id) }
                }
            } else {
                Toggle("Show feed names", isOn: $showNames)
            }
            if !controller.available.isEmpty {
                Text("Feed names").font(.subheadline).padding(.top, 4)
                ForEach(controller.available) { f in
                    FeedNameRow(info: f)
                }
            }
            Text("A clean full screen picture on the chosen display, for a vision mixer, projector or TV. The grid shows every open goggles window and marks a feed with no signal; one feed shows just that picture. Names never include the goggles serial number. Zebra stripes and peaking are not drawn here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ProgramOutputController.screenInfos()
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
