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
        VStack(alignment: .leading, spacing: 8) {
            Text("Event hooks").font(.headline)
            Text("Run a program and/or POST a webhook when something happens. The program gets the event name as its only argument, the JSON on stdin, and GOGGLES_EVENT / GOGGLES_PAYLOAD in its environment. 10 s limit. Nothing runs unless set here.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AppEvent.allCases) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.rawValue).font(.subheadline.bold())
                    HStack {
                        Text(scripts[event].flatMap { $0.isEmpty ? nil : $0 } ?? "No program")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { choose(event) }
                        Button("Clear") { set(script: "", for: event) }.disabled((scripts[event] ?? "").isEmpty)
                    }
                    TextField("Webhook URL (https://…)", text: Binding(
                        get: { webhooks[event] ?? "" },
                        set: { webhooks[event] = $0; SecretStore.set($0, for: EventHookConfig.webhookKey(event)) }
                    )).textFieldStyle(.roundedBorder).font(.caption)
                    if let w = webhooks[event], !w.isEmpty, EventHookLogic.validWebhook(w) == nil {
                        Text("Must be an http(s) URL").font(.caption2).foregroundStyle(.red)
                    }
                    Button("Test") { EventBus.shared.post(event, payload: ["test": true]) }
                        .controlSize(.small)
                }
            }
            Stepper("batteryLow threshold: \(battery)%", value: $battery, in: 1...99)
            HStack {
                Text("Recent runs").font(.subheadline.bold())
                Spacer()
                Button("Clear") { log.clear() }.controlSize(.small).disabled(log.runs.isEmpty)
            }
            if log.runs.isEmpty {
                Text("No runs yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(log.runs) { run in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(run.date.formatted(date: .omitted, time: .standard)) \(run.event.rawValue) → \(run.exitCode.map { "exit \($0)" } ?? "failed")")
                        .font(.caption.bold())
                    Text(run.target).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !run.output.isEmpty { Text(run.output).font(.caption2.monospaced()).lineLimit(3) }
                }
            }
        }
        .onAppear {
            for e in AppEvent.allCases { scripts[e] = EventHookConfig.script(e); webhooks[e] = EventHookConfig.webhook(e) }
        }
    }

    private func set(script: String, for event: AppEvent) {
        scripts[event] = script
        UserDefaults.standard.set(script, forKey: EventHookConfig.scriptKey(event))
    }

    private func choose(_ event: AppEvent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an executable to run on \(event.rawValue)"
        if panel.runModal() == .OK, let url = panel.url { set(script: url.path, for: event) }
    }
}
#endif
