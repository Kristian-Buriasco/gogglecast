import SwiftUI
import ServiceManagement

/// Settings row: opt in/out of opening the app when the goggles are plugged in.
/// Status is read live from SMAppService, never mirrored into stored state.
struct AutoOpenSettingsSection: View {
    @State private var isOn = AutoOpenRegistration.isOptedIn
    @State private var status = AutoOpenRegistration.status
    @State private var error: String?

    var body: some View {
        SettingsGroup("Auto-open") {
            SettingsToggleRow("Open GogglesView when goggles are plugged in", isOn: Binding(
                get: { isOn },
                set: { apply($0) }
            ), info: "macOS may ask you to approve this in System Settings > Login Items & Extensions.")
            SettingsRow("Status", help: error.map { LocalizedStringKey($0) }) {
                Text(HelperRegistration.plainDescription(status)).foregroundStyle(.secondary)
                if status == .requiresApproval {
                    Button("Open Login Items Settings…") { AutoOpenRegistration.openLoginItemsSettings() }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func apply(_ on: Bool) {
        error = nil
        do {
            if on { try AutoOpenRegistration.register() } else { try AutoOpenRegistration.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        status = AutoOpenRegistration.status
        isOn = AutoOpenRegistration.isOptedIn
    }
}
