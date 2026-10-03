#if canImport(AppKit)
import SwiftUI
import AppKit

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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.weight(.medium))
                        if let fix = item.fix {
                            Text(fix).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if item.action == .openLoginItems {
                            Button("Open Login Items & Extensions") {
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
    private static func color(_ s: SetupChecklist.Status) -> Color {
        switch s {
        case .pass: return .green
        case .fail: return .red
        case .unknown: return .secondary
        }
    }
}

/// First-run onboarding. Registration is live (polled); reachability/USB
/// aren't known here (no client), so they show as "not checked".
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var registration = SetupChecklist.Registration(HelperRegistration.status)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to GogglesView").font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("1. On the goggles: Settings > About > OTG Wired Connection to Computer. Unplug the cable before toggling.")
                Text("2. Connect with a USB-C data cable (not charge-only). Try another port if nothing shows up.")
                Text("3. Approve the helper in System Settings > Login Items & Extensions.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            SetupChecklistView(items: SetupChecklist.items(registration: registration, reachability: .unknown, devicesFound: nil))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding-done")
            }
        }
        .padding(22)
        .frame(width: 460, height: 440, alignment: .top)
        .background(AppChrome.backgroundColor)
        .foregroundStyle(.white)
        .onReceive(timer) { _ in registration = SetupChecklist.Registration(HelperRegistration.status) }
    }
}

enum OnboardingWindow {
    static let completedKey = "onboardingCompleted"
    private static var window: NSWindow?

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Shows the onboarding window (reusable from Settings). Marks it completed on Done.
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: OnboardingView(onDone: { finish() }))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 460, height: 440))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// First-launch gate for main.swift.
    static func showIfFirstRun() {
        if !isCompleted { show() }
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        window?.close()
        window = nil
    }
}

/// Settings > General: reopen onboarding.
struct OnboardingSettingsSection: View {
    var body: some View {
        HStack {
            Button("Show setup guide…") { OnboardingWindow.show() }
            Spacer()
        }
    }
}
#endif
