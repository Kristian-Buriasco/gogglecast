import SwiftUI
import ServiceManagement

/// Settings row: opt in/out of opening the app when the goggles are plugged in.
/// Status is read live from SMAppService, never mirrored into stored state.
struct AutoOpenSettingsSection: View {
    @State private var isOn = AutoOpenRegistration.isOptedIn
    @State private var status = AutoOpenRegistration.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open GogglesView when goggles are plugged in", isOn: Binding(
                get: { isOn },
                set: { apply($0) }
            ))
            Text("Status: \(HelperRegistration.plainDescription(status))")
                .font(.caption).foregroundStyle(.secondary)
            if status == .requiresApproval {
                Button("Open Login Items Settings…") { AutoOpenRegistration.openLoginItemsSettings() }
            }
            Text("macOS may ask you to approve this in System Settings > Login Items & Extensions.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
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
