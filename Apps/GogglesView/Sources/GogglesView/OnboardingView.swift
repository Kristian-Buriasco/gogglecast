#if canImport(AppKit)
import SwiftUI
import AppKit
import ServiceManagement

/// Rows for a `SetupChecklist`, with fix text and the Login Items button.
struct SetupChecklistView: View {
    let items: [SetupChecklist.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(item.status))
                        .foregroundStyle(Self.color(item.status))
                        .frame(width: 18)
                        .accessibilityLabel(Self.statusText(item.status))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.weight(.medium))
                        if let fix = item.fix {
                            Text(fix).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if item.action == .openLoginItems {
                            Button("Open System Settings") {
                                if let url = URL(string: SetupChecklist.loginItemsURL) { NSWorkspace.shared.open(url) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .accessibilityIdentifier("checklist-\(item.id)")
            }
        }
    }

    private static func symbol(_ s: SetupChecklist.Status) -> String {
        switch s {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private static func statusText(_ s: SetupChecklist.Status) -> String {
        switch s {
        case .pass: return "Passed"
        case .fail: return "Needs attention"
        case .unknown: return "Not checked"
        }
    }
    private static func color(_ s: SetupChecklist.Status) -> Color {
        switch s {
        case .pass: return .green
        case .fail: return .red
        case .unknown: return .secondary
        }
    }
}

/// What the assistant can observe and do. `main.swift` wires the real values
/// (helper connection, open goggles sessions); the defaults only know what
/// the app can see on its own (service registration and USB).
struct SetupAssistantEnvironment {
    var registration: () -> SetupChecklist.Registration = { SetupChecklist.Registration(HelperRegistration.status) }
    var reachability: () -> SetupChecklist.Reachability = { .unknown }
    var usbSeen: () -> Bool = { GogglesUSBPresence.isPresent() }
    /// UI states of all open goggles windows.
    var states: () -> [GogglesUIState] = { [] }
    /// Opens a goggles session in the background when exactly one pair is on USB and none is open yet.
    var ensureSession: () -> Void = {}
    var reconnect: () -> Void = {}
    var retry: () -> Void = {}
    /// Called by Done: shows the live window.
    var finish: () -> Void = {}
}

/// Polls the environment every second (driven by the view's timer) and
/// publishes the four setup steps.
final class SetupAssistantModel: ObservableObject {
    @Published private(set) var steps: [SetupDiagnosis.Step] = []
    /// Real error from the last attempt to set up the background service.
    @Published var errorMessage: String?
    let env: SetupAssistantEnvironment

    init(env: SetupAssistantEnvironment) {
        self.env = env
        steps = computeSteps()
        // The background service failed to restart after an update: show it on its step.
        errorMessage = UpdateInstaller.shared.helperUpdateError
    }

    var isComplete: Bool { SetupDiagnosis.isComplete(steps) }

    private func computeSteps() -> [SetupDiagnosis.Step] {
        let states = env.states()
        let helper = SetupDiagnosis.Helper.from(registration: env.registration(), reachability: env.reachability())
        return SetupDiagnosis.evaluate(
            helper: helper, usbSeen: env.usbSeen(),
            claim: SetupDiagnosis.claim(from: states), video: SetupDiagnosis.video(from: states))
    }

    func refresh() {
        let updated = computeSteps()
        if updated != steps { steps = updated }
        // Helper ready and goggles on USB but nothing open yet: connect in the
        // background so the video step can actually go green.
        if updated[0].state == .done, updated[1].state == .done, env.states().isEmpty {
            env.ensureSession()
        }
        if updated[0].state == .done, UpdateInstaller.shared.helperUpdateError == nil { errorMessage = nil }
    }

    func perform(_ action: SetupDiagnosis.Step.Action) {
        switch action {
        case .openSystemSettings:
            SMAppService.openSystemSettingsLoginItems()
        case .registerHelper:
            errorMessage = HelperRegistration.registerForUser()
        case .reconnectHelper:
            env.reconnect()
        case .retryConnection:
            env.retry()
        }
        refresh()
    }
}

/// The setup assistant: checks each prerequisite live and shows one plain
/// sentence and at most one button per step. Replaces the old welcome screen.
struct OnboardingView: View {
    @StateObject private var model: SetupAssistantModel
    var onDone: () -> Void
    var onClose: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(environment: SetupAssistantEnvironment = SetupAssistantEnvironment(), onDone: @escaping () -> Void, onClose: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: SetupAssistantModel(env: environment))
        self.onDone = onDone
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up GogglesView").font(.title2.bold())
            Text("This checks each step as you go and tells you what to do next.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, number: index + 1, total: model.steps.count,
                                error: step.id == .helper ? model.errorMessage : nil) { model.perform($0) }
                    }
                }
            }
            if model.isComplete {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text("You're set. Your goggles are connected and video is arriving.").font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("setup-complete")
            }
            HStack {
                Spacer()
                if model.isComplete {
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                        .accessibilityHint("Closes the assistant and shows the live window")
                        .accessibilityIdentifier("onboarding-done")
                } else {
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                        .accessibilityHint("Closes the assistant. You can reopen it from the Help menu")
                        .accessibilityIdentifier("onboarding-close")
                }
            }
        }
        .padding(22)
        .frame(width: 520, height: 640, alignment: .top)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onReceive(timer) { _ in model.refresh() }
        .onAppear { model.refresh() }
    }
}

private struct StepRow: View {
    let step: SetupDiagnosis.Step
    let number: Int
    let total: Int
    let error: String?
    let perform: (SetupDiagnosis.Step.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(step.title)").font(.headline)
                Text(step.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !step.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(step.instructions.enumerated()), id: \.offset) { i, text in
                            Text("\(i + 1). \(text)").font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 4)
                }
                ForEach(step.hints, id: \.self) { hint in
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup-error")
                }
                if let action = step.action {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                        .accessibilityIdentifier("setup-action-\(step.id.rawValue)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .opacity(step.state == .pending ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccessibilityLabels.setupStep(number: number, of: total, title: step.title, state: step.state, message: step.message))
        .accessibilityIdentifier("setup-step-\(step.id.rawValue)")
    }

    private var symbol: String {
        switch step.state {
        case .done: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .pending: return "circle"
        }
    }

    private var color: Color {
        switch step.state {
        case .done: return .green
        case .attention: return .orange
        case .pending: return .gray
        }
    }
}

enum OnboardingWindow {
    static let completedKey = "onboardingCompleted"
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// Wired by `main.swift`; the default only sees what the app can see by itself.
    static var environment = SetupAssistantEnvironment()

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Shows the setup assistant (also reachable from Settings, the Help menu and every failure state).
    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: OnboardingView(
            environment: environment,
            onDone: { finish(openLive: true) },
            onClose: { finish(openLive: false) }))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Setup assistant"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 520, height: 640))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        // The red close button counts as finishing, so the assistant doesn't reappear at every launch.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: completedKey)
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            window = nil
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// First-launch gate for main.swift.
    static func showIfFirstRun() {
        if !isCompleted { show() }
    }

    private static func finish(openLive: Bool) {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
        window = nil
        if openLive { environment.finish() }
    }
}

/// Settings: reopen the setup assistant.
struct OnboardingSettingsSection: View {
    var body: some View {
        HStack {
            Button("Open setup assistant…") { OnboardingWindow.show() }
                .accessibilityHint("Opens a guided checklist for the background service, USB connection and video")
                .accessibilityIdentifier("openSetupAssistantButton")
            Spacer()
        }
    }
}
#endif
