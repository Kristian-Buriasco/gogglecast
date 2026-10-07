import AppKit
import SwiftUI
import GogglesXPC

/// Builds the plain-text bug-report blob. Formatting/redaction/truncation helpers are pure (see DiagnosticsReportTests).
enum DiagnosticsReport {
    static let logTailLines = 150
    static let maxLogBytes = 64 * 1024
    static let logTimeout: TimeInterval = 10

    // MARK: Pure helpers

    /// Replaces the home directory with `~`.
    static func redactHome(_ s: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return s }
        return s.replacingOccurrences(of: home, with: "~")
    }

    /// Only the last 4 characters of a serial survive.
    static func redactSerial(_ s: String) -> String {
        s.count <= 4 ? String(repeating: "*", count: s.count) : "…" + s.suffix(4)
    }

    /// Last `lines` lines, then truncated (from the front) to `maxBytes`.
    static func tail(_ text: String, lines: Int = logTailLines, maxBytes: Int = maxLogBytes) -> String {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.last == "" { all.removeLast() }
        var out = all.suffix(lines).joined(separator: "\n")
        if out.utf8.count > maxBytes {
            out = "[truncated]\n" + String(decoding: Array(out.utf8.suffix(maxBytes)), as: UTF8.self)
        }
        return out
    }

    static func formatSettings(_ pairs: [(String, Any)], home: String = NSHomeDirectory()) -> String {
        pairs.map { "  \($0.0) = " + redactHome("\($0.1)", home: home) }.joined(separator: "\n")
    }

    static func assemble(sections: [(String, String)]) -> String {
        sections.map { "== \($0.0) ==\n\($0.1)" }.joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return f.string(from: date)
    }

    // MARK: Collection

    static let settingsKeys: [String] = [
        RecordingPrefs.folderKey, RecordingPrefs.containerKey, RecordingPrefs.prefixKey, RecordingPrefs.autoStartKey,
        OSDPrefs.enabledKey, OSDPrefs.showFpsKey, OSDPrefs.showBitrateKey, OSDPrefs.showResolutionKey,
        OSDPrefs.showDropsKey, OSDPrefs.showLatencyKey, OSDPrefs.showBatteryKey,
        ReplayPrefs.enabledKey, ReplayPrefs.secondsKey,
        NetStreamPrefs.hostKey, NetStreamPrefs.portKey, NetStreamPrefs.autoStartKey,
        CaptureWindowPrefs.enabledKey, CaptureWindowPrefs.onTopKey,
        SessionLogPrefs.enabledKey, SessionLogPrefs.retentionDaysKey,
        AutomationPrefs.enabledKey,
    ] + RecordingExtras.allKeys

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func cpuArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Blocking; up to `timeout` seconds. Never throws.
    static func runLogShow(timeout: TimeInterval = logTimeout) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--predicate", "subsystem BEGINSWITH \"com.kburiasco.gogglesview\"",
                       "--style", "compact", "--last", "10m", "--info"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "(log show failed to launch: \(error.localizedDescription))" }
        // Drain on a background queue so a full pipe never blocks the child.
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        var note = ""
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            note = "(log show timed out after \(Int(timeout))s; output may be partial)\n"
        } else {
            p.waitUntilExit()
            if p.terminationStatus != 0 { note = "(log show exited with status \(p.terminationStatus))\n" }
        }
        let text = String(decoding: box.data, as: UTF8.self)
        return note + (text.isEmpty ? "(no log lines)" : tail(text))
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Blocking (up to ~10s for the log query); call off the main thread.
    static func collect() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = """
        version: \(info["CFBundleShortVersionString"] as? String ?? "unknown") (build \(info["CFBundleVersion"] as? String ?? "unknown"))
        bundle id: \(Bundle.main.bundleIdentifier ?? "unknown")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        hardware model: \(sysctlString("hw.model"))
        cpu arch: \(cpuArch())
        """
        let helper = """
        registration: SMAppService.daemon: \(HelperRegistration.describe(HelperRegistration.status))
        app expects protocol version: \(GogglesXPC.currentProtocolVersion)
        connection health: \(HealthDiagnostics.summaryLine)
        """
        let connection = ConnectionTrace.shared.text
        let defaults = UserDefaults.standard
        let pairs: [(String, Any)] = settingsKeys.compactMap { k in defaults.object(forKey: k).map { (k, $0) } }
        let settings = pairs.isEmpty ? "  (all defaults)" : formatSettings(pairs)
        return assemble(sections: [
            ("App", app), ("Helper", helper), ("Connection events", connection), ("Settings", settings),
            ("Logs (last 10m, last \(logTailLines) lines)", redactHome(runLogShow())),
        ])
    }
}

/// Settings UI: copy or save the diagnostics report.
extension DiagnosticsReport {
    /// Collects the report off the main thread and copies it to the pasteboard.
    static func copyToPasteboard(completion: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = collect()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                completion()
            }
        }
    }
}

/// Retry, Copy diagnostics and Open setup assistant: shown on every failed state.
struct RecoveryActionsRow: View {
    var onRetry: (() -> Void)?
    @State private var collecting = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if let onRetry {
                Button("Retry", action: onRetry)
                    .accessibilityHint("Tries to connect to the goggles again")
                    .accessibilityIdentifier("recoveryRetryButton")
            }
            Button(copied ? "Copied" : (collecting ? "Collecting…" : "Copy diagnostics")) {
                collecting = true
                copied = false
                DiagnosticsReport.copyToPasteboard {
                    collecting = false
                    copied = true
                }
            }
            .disabled(collecting)
            .accessibilityHint("Copies technical details to the clipboard so you can send them to support")
            .accessibilityIdentifier("recoveryCopyDiagnosticsButton")
            Button("Open setup assistant") { OnboardingWindow.show() }
                .accessibilityHint("Opens a guided checklist that finds the problem")
                .accessibilityIdentifier("recoverySetupAssistantButton")
        }
        .controlSize(.small)
    }
}

struct DiagnosticsSettingsSection: View {
    @State private var collecting = false
    @State private var copied = false

    var body: some View {
        HStack {
            Button("Copy diagnostics") {
                run { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
            }
            Button("Save to file…") { run { save($0) } }
            if collecting {
                ProgressView().controlSize(.small)
                Text("Collecting…").foregroundStyle(.secondary)
            } else if copied {
                Text("Copied").foregroundStyle(.secondary)
            }
        }
        .disabled(collecting)
    }

    private func run(_ finish: @escaping (String) -> Void) {
        collecting = true
        copied = false
        DispatchQueue.global(qos: .userInitiated).async {
            let text = DiagnosticsReport.collect()
            DispatchQueue.main.async {
                collecting = false
                finish(text)
            }
        }
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GogglesView-diagnostics-\(DiagnosticsReport.timestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
