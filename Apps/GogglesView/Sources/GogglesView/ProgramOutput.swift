import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
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
    /// OutputResolution raw value; nil (older saved JSON) = "default" = never change the display.
    var resolution: String?

    var outputResolution: OutputResolution { resolution.flatMap(OutputResolution.init(rawValue:)) ?? .displayDefault }
    var isGrid: Bool { layout != "single" }
}

enum ProgramOutputPrefs {
    static let enabledKey = "programOutputEnabled"
    static let outputsKey = "programOutputList"          // JSON [ProgramOutputConfig]
    static let feedNamesKey = "programOutputFeedNames"  // [deviceId: custom name]
    static let openAtLaunchKey = "programOutputOpenAtLaunch"
    static let cleanKey = "programOutputClean"            // no names, NO SIGNAL text, warnings or red border
    static let stabilizeKey = "programOutputStabilize"    // run the stabilizer while the outputs are shown, even in race mode
    static let maxOutputs = 4

    static func clean(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: cleanKey) }
    /// The stabilizer sits in the shared decode path, so this stabilizes the preview too.
    static func stabilizeActive(_ d: UserDefaults = .standard) -> Bool { enabled(d) && d.bool(forKey: stabilizeKey) }

    /// The program outputs are full-screen windows. Unless the user asked for them at launch, start with them off,
    /// so a Mac that quit with them on does not come back hidden behind a full-screen picture.
    static func resetAtLaunch(_ d: UserDefaults = .standard) {
        if !d.bool(forKey: openAtLaunchKey) { d.set(false, forKey: enabledKey) }
    }

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
    /// Pixel size such as "1920 × 1080", empty when unknown.
    var resolution = ""
}

/// What the settings card tells the user about one output.
enum ProgramOutputStatus: Equatable {
    case off                      // the program outputs are switched off
    case noDisplay                // no display for this output (unplugged, or already used by an earlier output)
    case showing(String)          // on this external display
    case onMain(String)           // on the main display: covers the controls

    static func status(index: Int, outputs: [ProgramOutputConfig], screens: [ProgramScreenInfo], enabled: Bool) -> ProgramOutputStatus {
        guard enabled else { return .off }
        let assigned = ProgramDisplayChoice.assign(outputs: outputs, screens: screens)
        guard index < assigned.count, let id = assigned[index], let s = screens.first(where: { $0.id == id }) else { return .noDisplay }
        return s.isMain ? .onMain(s.name) : .showing(s.name)
    }
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
    /// The name the crew gave this feed, or `fallback` (the window title) when there is none.
    static func displayName(deviceId: String, fallback: String, custom: [String: String] = ProgramOutputPrefs.feedNames()) -> String {
        let c = custom[deviceId].map(ProgramOutputPrefs.sanitizeName) ?? ""
        return c.isEmpty ? fallback : c
    }

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
    @ObservedObject private var status = EventStatus.shared
    @State private var pulse = false

    private var lost: Bool { showSignal && coordinator.uiState.kind != .live }
    private var issueText: String {
        status.rows.first { $0.id == feed.id }?.issues.map(\.text).joined(separator: " · ") ?? ""
    }

    init(feed: ProgramFeed, showName: Bool, showSignal: Bool) {
        self.feed = feed; self.showName = showName; self.showSignal = showSignal
        self.coordinator = feed.coordinator
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            GogglesVideoView(session: feed.session, isSecondary: true, isProgram: true)
            if showSignal && coordinator.uiState.kind != .live {
                Color.black.opacity(0.6)
                Text(verbatim: L("NO SIGNAL")).font(.system(size: 28, weight: .bold)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showSignal && !lost && !issueText.isEmpty {
                Text(verbatim: issueText)
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if showName {
                Text(verbatim: feed.name)
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
            }
        }
        .overlay {
            if lost {
                Rectangle().stroke(Color.red, lineWidth: 8).opacity(pulse ? 1 : 0.15)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }
                    .onDisappear { pulse = false }
            }
        }
        .clipped()
    }
}

private struct ProgramOutputView: View {
    let feeds: [ProgramFeed]
    let showNames: Bool
    let multiview: Bool
    let clean: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(feeds.enumerated()), id: \.element.id) { i, feed in
                    let r = ProgramLayoutMath.tile(index: i, count: feeds.count, in: geo.size)
                    ProgramTile(feed: feed, showName: showNames && multiview && !clean, showSignal: multiview && !clean)
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
    /// Enabled program outputs with no display to show on (HDMI unplugged), for the remote alerts.
    private(set) var missingOutputs: [String] = []

    private var sessions: () -> [GogglesSession] = { [] }
    private var active: () -> GogglesSession? = { nil }
    private var windows: [String: NSWindow] = [:]   // output id -> window
    private var shownKeys: [String: String] = [:]
    private var observers: [AnyCancellable] = []
    private var pending: DispatchWorkItem?
    private let resolutions = DisplayResolutionManager(configurator: CoreGraphicsDisplayConfigurator())
    /// Per output id: what happened with its resolution request (shown in the status line).
    @Published private(set) var resolutionResults: [String: ResolutionResult] = [:]
    private var panicRef: EventHotKeyRef?
    private var panicHandler: EventHandlerRef?

    /// Emergency close, works from any app: for example when an output landed on the only screen and the
    /// picture covers the controls. Registered only while an output is on screen.
    static let panicCombo = HotkeyCombo(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
    private static let panicID = EventHotKeyID(signature: OSType(0x47565050), id: 1) // 'GVPP'

    /// Panic hotkey + preview state follow whether an output window is on screen (so the preview always returns when they close).
    private func settle() {
        updatePanicHotkey()
        PreviewState.shared.update(hdmiOnly: UserDefaults.standard.bool(forKey: PreviewPolicy.hdmiOnlyKey), outputsShown: !windows.isEmpty)
    }

    private func updatePanicHotkey() {
        guard !windows.isEmpty else { removePanicHotkey(); return }
        guard panicRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Other hotkeys share the application target: leave theirs to their own handler.
            guard id.signature == ProgramOutputController.panicID.signature, id.id == ProgramOutputController.panicID.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { UserDefaults.standard.set(false, forKey: ProgramOutputPrefs.enabledKey) }
            return noErr
        }, 1, &spec, nil, &panicHandler)
        RegisterEventHotKey(Self.panicCombo.keyCode, Self.panicCombo.carbonModifiers, Self.panicID,
                            GetApplicationEventTarget(), 0, &panicRef)
    }

    private func removePanicHotkey() {
        if let panicRef { UnregisterEventHotKey(panicRef) }
        panicRef = nil
        if let panicHandler { RemoveEventHandler(panicHandler) }
        panicHandler = nil
    }

    func install(sessions: @escaping () -> [GogglesSession], active: @escaping () -> GogglesSession?) {
        self.sessions = sessions
        self.active = active
        ProgramOutputPrefs.resetAtLaunch()
        observers = [
            // forAppOnly already covers crashes; this puts the mode back on a normal quit.
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                .sink { [weak self] _ in self?.resolutions.restoreAll() },
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
            let px = CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
            return ProgramScreenInfo(id: id, name: s.localizedName, isMain: s == NSScreen.screens.first,
                                     resolution: "\(Int(px.width)) × \(Int(px.height))")
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

    private func syncResolutions(_ desired: [UInt32: OutputResolution], outputs: [(id: String, display: UInt32?)]) {
        let byDisplay = resolutions.sync(desired)
        var results: [String: ResolutionResult] = [:]
        for o in outputs { if let d = o.display, let r = byDisplay[d] { results[o.id] = r } }
        if results != resolutionResults { resolutionResults = results }
    }

    func refresh() {
        let all = sessions()
        let names = ProgramFeedNaming.names(deviceIds: all.map(\.deviceId), custom: ProgramOutputPrefs.feedNames())
        let info = zip(all, names).map { ProgramFeedInfo(id: $0.deviceId, name: $1) }
        if info != available { available = info }

        let outputs = ProgramOutputPrefs.outputs()
        for id in Set(windows.keys).subtracting(outputs.map(\.id)) { close(id) }
        guard ProgramOutputPrefs.enabled() else { missingOutputs = []; for id in Array(windows.keys) { close(id) }; syncResolutions([:], outputs: []); settle(); return }

        let assigned = ProgramDisplayChoice.assign(outputs: outputs, screens: Self.screenInfos())
        missingOutputs = zip(outputs.indices, assigned).filter { $0.1 == nil }.map { L("Program output %lld", $0.0 + 1) }
        var desired: [UInt32: OutputResolution] = [:]
        for (output, displayID) in zip(outputs, assigned) { if let displayID { desired[displayID] = output.outputResolution } }
        syncResolutions(desired, outputs: zip(outputs, assigned).map { (id: $0.id, display: $1) })
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
            let clean = ProgramOutputPrefs.clean()
            let key = "\(displayID)|\(screen.frame)|\(output.layout)|\(output.showNames)|\(clean)|" + feeds.map { "\($0.id):\($0.name)" }.joined(separator: ",")
            guard key != shownKeys[output.id] else { continue }
            shownKeys[output.id] = key

            let host = NSHostingView(rootView: ProgramOutputView(feeds: feeds, showNames: output.showNames, multiview: output.isGrid, clean: clean))
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
        settle()
    }
}

struct ProgramOutputSettingsSection: View {
    @ObservedObject private var controller = ProgramOutputController.shared
    @AppStorage(ProgramOutputPrefs.enabledKey) private var enabled = false
    @AppStorage(ProgramOutputPrefs.openAtLaunchKey) private var openAtLaunch = false
    @AppStorage(ProgramOutputPrefs.cleanKey) private var clean = false
    @AppStorage(ProgramOutputPrefs.stabilizeKey) private var stabilize = false
    @AppStorage(PreviewPolicy.hdmiOnlyKey) private var previewHdmiOnly = false
    private var previewOnMac: Binding<Bool> { Binding(get: { !previewHdmiOnly }, set: { previewHdmiOnly = !$0 }) }
    @State private var outputs = ProgramOutputPrefs.outputs()
    @State private var screens = ProgramOutputController.screenInfos()

    var body: some View {
        Group {
            SettingsGroup("Program outputs",
                          info: "A clean full screen picture on each chosen display, for a vision mixer, projector or TV: one output per HDMI connection. A grid shows every open goggles window and marks a feed with no signal; one feed shows just that picture. Names never include the goggles serial number. Zebra stripes and peaking are not drawn here.") {
                SettingsToggleRow("Show the program outputs", isOn: $enabled)
                SettingsToggleRow("Open the program outputs when the app starts", isOn: $openAtLaunch)
                SettingsToggleRow("Clean output", isOn: $clean, help: "Hides all names, warnings and the no-signal marker.")
                SettingsToggleRow("Stabilize output", isOn: $stabilize, help: "Also stabilizes the preview. Works in race mode.")
                SettingsToggleRow("Preview in the app", isOn: previewOnMac, help: "Draw the picture on the HDMI outputs only, to lighten the Mac.")
                SettingsRow("Emergency close") {
                    Text("Stuck behind a full-screen output? Press ⌃⌥⌘. in any app to close all program outputs.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup("Connected displays") {
                let assigned = ProgramDisplayChoice.assign(outputs: outputs, screens: screens)
                ForEach(screens, id: \.id) { s in
                    DisplayRow(screen: s, user: assigned.firstIndex(of: s.id))
                }
            }
            ForEach($outputs) { $o in
                OutputGroup(index: outputs.firstIndex { $0.id == o.id } ?? 0, output: $o, outputs: outputs, screens: screens, enabled: enabled,
                            feeds: controller.available, canRemove: outputs.count > 1,
                            resolutionResult: controller.resolutionResults[o.id]) { outputs.removeAll { $0.id == o.id } }
            }
            if outputs.count < ProgramOutputPrefs.maxOutputs {
                Button(L("Add output (%lld of %lld)", outputs.count + 1, ProgramOutputPrefs.maxOutputs)) {
                    outputs.append(ProgramOutputConfig())
                }
                .fixedSize()
            }
            if !controller.available.isEmpty {
                SettingsGroup("Feed names") {
                    ForEach(controller.available) { f in FeedNameRow(info: f) }
                }
            }
        }
        .onChange(of: outputs) { ProgramOutputPrefs.setOutputs($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ProgramOutputController.screenInfos()
        }
    }
}

private struct DisplayRow: View {
    let screen: ProgramScreenInfo
    let user: Int?   // index of the output using this display

    var body: some View {
        SettingsRow(screen.name.isEmpty ? "Display" : LocalizedStringKey(screen.name)) {
            HStack(spacing: 8) {
                Text(verbatim: screen.isMain ? L("Main") : L("External"))
                    .font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(screen.isMain ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.2)))
                    .fixedSize()
                if !screen.resolution.isEmpty { Text(verbatim: screen.resolution).font(.caption).foregroundStyle(.secondary).fixedSize() }
                Spacer(minLength: 0)
                Text(verbatim: user.map { L("Output %lld", $0 + 1) } ?? L("free"))
                    .foregroundStyle(user == nil ? .secondary : .primary)
            }
        }
    }
}

private struct OutputGroup: View {
    let index: Int
    @Binding var output: ProgramOutputConfig
    let outputs: [ProgramOutputConfig]
    let screens: [ProgramScreenInfo]
    let enabled: Bool
    let feeds: [ProgramFeedInfo]
    let canRemove: Bool
    var resolutionResult: ResolutionResult?
    let remove: () -> Void

    private var status: ProgramOutputStatus {
        ProgramOutputStatus.status(index: index, outputs: outputs, screens: screens, enabled: enabled)
    }

    var body: some View {
        SettingsGroup(LocalizedStringKey(L("Output %lld", index + 1))) {
            statusRow
            SettingsRow("Display") {
                Picker("Display", selection: Binding(get: { Int(output.display) }, set: { output.display = UInt32($0) })) {
                    Text("Automatic (next external display)").tag(0)
                    ForEach(screens, id: \.id) { s in
                        Text(verbatim: s.isMain ? "\(s.name) (\(L("main display")))" : s.name).tag(Int(s.id))
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            SettingsRow("Output resolution", help: "Lowers the load on the Mac when the display is 4K.") {
                Picker("Output resolution", selection: Binding(get: { output.outputResolution },
                                                               set: { output.resolution = $0 == .displayDefault ? nil : $0.rawValue })) {
                    Text("Display default").tag(OutputResolution.displayDefault)
                    Text(verbatim: "1080p").tag(OutputResolution.p1080)
                    Text(verbatim: "720p").tag(OutputResolution.p720)
                }
                .labelsHidden().frame(width: 260)
                .accessibilityLabel(Text("Output resolution"))
            }
            SettingsRow("Show") {
                Picker("Show", selection: $output.layout) {
                    Text("All feeds in a grid").tag("grid")
                    Text("One feed").tag("single")
                }
                .labelsHidden().frame(width: 260)
            }
            if output.isGrid {
                SettingsToggleRow("Show feed names", isOn: $output.showNames, indented: true)
            } else {
                SettingsRow("Feed", indented: true) {
                    Picker("Feed", selection: $output.feed) {
                        Text("Follow the active window").tag("")
                        ForEach(feeds) { f in Text(verbatim: f.name).tag(f.id) }
                    }
                    .labelsHidden().frame(width: 260)
                }
            }
            if canRemove {
                SettingsRow("Remove") { Button("Remove output", role: .destructive, action: remove).fixedSize() }
            }
        }
    }

    private var statusRow: some View {
        let (color, text): (Color, String) = {
            switch status {
            case .off: return (.gray, L("Off"))
            case .noDisplay: return (.orange, L("No display connected"))
            case .showing(let n):
                switch resolutionResult {
                case .applied(let r)?: return (.green, L("Showing on %@ at %@", n, r))
                case .refusedMain?: return (.orange, L("Showing on %@. Resolution not changed: the main display is never changed.", n))
                case .noMatchingMode(let r)?: return (.orange, L("Showing on %@. Resolution not changed: no %@ mode on this display.", n, r))
                case .failed?: return (.orange, L("Showing on %@. Resolution not changed: macOS refused the change.", n))
                case nil: return (.green, L("Showing on %@", n))
                }
            case .onMain:
                let base = L("Main display: it will cover your controls")
                return (.orange, resolutionResult == .refusedMain ? base + " " + L("The main display's resolution is never changed.") : base)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: L("Output %lld", index + 1) + ": " + text))
    }
}

private struct FeedNameRow: View {
    let info: ProgramFeedInfo
    @State private var text = ""

    var body: some View {
        SettingsRow(LocalizedStringKey(info.name)) {
            TextField(text: $text, prompt: Text(verbatim: info.name)) { Text("Name") }
                .labelsHidden()
                .settingsField(width: 240, mono: false)
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
