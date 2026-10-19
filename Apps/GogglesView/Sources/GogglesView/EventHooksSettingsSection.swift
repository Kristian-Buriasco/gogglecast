#if canImport(AppKit)
import SwiftUI
import AppKit

/// Settings UI for scripting hooks: per-event program + webhook, battery threshold, last-50-runs log.
struct EventHooksSettingsSection: View {
    @State private var scripts: [AppEvent: String] = [:]
    @State private var webhooks: [AppEvent: String] = [:]
    @AppStorage(EventHookConfig.batteryKey) private var battery = EventHookConfig.defaultBattery
    @ObservedObject private var log = HookLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Event hooks",
                          info: "Run a program and/or POST a webhook when something happens. The program gets the event name as its only argument, the JSON on stdin, and GOGGLES_EVENT / GOGGLES_PAYLOAD in its environment. 10 s limit. Nothing runs unless set here. Program paths are kept in the Keychain, so other apps can't change them.") {
                ForEach(AppEvent.allCases) { event in
                    SettingsRow(LocalizedStringKey(event.rawValue)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(scripts[event].flatMap { $0.isEmpty ? nil : $0 } ?? L("No program"))
                                    .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(.secondary).frame(maxWidth: 160, alignment: .leading)
                                Button("Choose…") { choose(event) }
                                Button("Clear") { set(script: "", for: event) }.disabled((scripts[event] ?? "").isEmpty)
                                Button("Test") { EventBus.shared.post(event, payload: ["test": true]) }
                            }
                            TextField("Webhook URL (https://…)", text: Binding(
                                get: { webhooks[event] ?? "" },
                                set: { webhooks[event] = $0; EventHookConfig.setWebhook($0, for: event) }
                            )).labelsHidden()
                                .settingsField(valid: (webhooks[event] ?? "").isEmpty ? nil : EventHookLogic.validWebhook(webhooks[event] ?? "") != nil)
                            if let w = webhooks[event], !w.isEmpty, EventHookLogic.validWebhook(w) == nil {
                                Text("Must be an http(s) URL").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                SettingsRow("batteryLow threshold") {
                    Stepper(value: $battery, in: 1...99) { Text(verbatim: "\(battery)%").monospacedDigit() }
                        .fixedSize()
                        .accessibilityLabel(Text(verbatim: L("batteryLow threshold: %lld%%", battery)))
                }
            }
            SettingsGroup("Recent runs") {
                SettingsRow("Log") {
                    Button("Clear") { log.clear() }.disabled(log.runs.isEmpty)
                    if log.runs.isEmpty { Text("No runs yet").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(log.runs) { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(run.date.formatted(date: .omitted, time: .standard)) \(run.event.rawValue) → \(run.exitCode.map { L("exit %lld", Int($0)) } ?? L("failed"))")
                            .font(.caption.bold())
                        Text(run.target).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !run.output.isEmpty { Text(run.output).font(.caption2.monospaced()).lineLimit(3) }
                    }
                    .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Divider().opacity(0.6) }
                }
            }
        }
        .onAppear {
            guard EventHookConfig.mayHaveHooks else { return }
            for e in AppEvent.allCases { scripts[e] = EventHookConfig.script(e); webhooks[e] = EventHookConfig.webhook(e) }
            EventHookConfig.noteConfigured(AppEvent.allCases.contains { !(scripts[$0] ?? "").isEmpty || !(webhooks[$0] ?? "").isEmpty })
        }
    }

    private func set(script: String, for event: AppEvent) {
        scripts[event] = script
        EventHookConfig.setScript(script, for: event)
    }

    private func choose(_ event: AppEvent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an executable to run on %@", event.rawValue)
        if panel.runModal() == .OK, let url = panel.url { set(script: url.path, for: event) }
    }
}
#endif
