import Foundation

// Native Shortcuts / Siri / Stream Deck actions (App Intents, macOS 14+).
// Every intent maps to an `AutomationCommand` and runs through
// `AutomationController.perform`, the same dispatcher as the URL scheme and
// AppleScript, so the "Allow automation" gate and the device targeting rules
// are identical. Intents run in the app process and never open a window.
//
// Note: Shortcuts only lists these if the bundle carries
// `Contents/Resources/Metadata.appintents`; `build-stub-bundle.sh` generates
// it (see docs/automation.md).

// MARK: - Pure helpers (unit-tested; no AppIntents dependency)

/// Snapshot of the frontmost (or targeted) goggles for the "Get status" action.
struct GogglesStatusSnapshot: Equatable {
    var gogglesCount: Int
    var recording: Bool
    var fps: Int?
    var batteryPercent: Int?

    /// One-line, human readable summary used as the action's dialog.
    var summary: String {
        guard gogglesCount > 0 else { return "No goggles window is open." }
        var parts = ["\(gogglesCount) goggles connected", recording ? "recording" : "not recording"]
        if let fps { parts.append("\(fps) fps") }
        if let batteryPercent { parts.append("battery \(batteryPercent)%") }
        return parts.joined(separator: ", ")
    }
}

enum ShortcutsMapping {
    /// Request for an action. Blank device = frontmost; returns nil when
    /// `device` is present but not a valid identifier.
    static func request(_ command: AutomationCommand, device: String?) -> AutomationRequest? {
        var clean: String?
        if let device, !device.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = AutomationURLParser.sanitizeDevice(device) else { return nil }
            clean = v
        }
        return AutomationRequest(command: command, device: clean)
    }

    /// Marker command with the same label sanitising as the URL scheme.
    static func markerCommand(label: String?) -> AutomationCommand {
        .addMarker(label: label.flatMap(AutomationURLParser.sanitizeLabel) ?? AutomationURLParser.defaultMarkerLabel)
    }

    /// Dialog shown on success.
    static func successMessage(_ command: AutomationCommand) -> String {
        switch command {
        case .startRecording: return "Recording started"
        case .stopRecording: return "Recording stopped"
        case .toggleRecording: return "Recording toggled"
        case .saveReplay: return "Instant replay saved"
        case .screenshot: return "Screenshot taken"
        case .toggleFreeze: return "Freeze toggled"
        case .addMarker(let label): return "Marker added: \(label)"
        case .startStream: return "Network stream started"
        case .stopStream: return "Network stream stopped"
        case .showWindow: return "Window shown"
        }
    }

    /// Readable failure text, or nil on success.
    static func failureMessage(disabled: Bool, noTarget: Bool, device: String?) -> String? {
        if disabled { return "Automation is turned off in GogglesView Settings > Advanced." }
        if noTarget {
            return device == nil
                ? "No goggles are live. Connect the goggles and open a GogglesView window first."
                : "No open goggles match that device."
        }
        return nil
    }

    static let invalidDeviceMessage = "Invalid device identifier."
}

#if canImport(AppIntents) && canImport(AppKit)
import AppIntents

// MARK: - Execution

struct ShortcutsError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
enum ShortcutsRunner {
    static func run(_ command: AutomationCommand, device: String?) throws -> String {
        guard let request = ShortcutsMapping.request(command, device: device) else {
            throw ShortcutsError(message: ShortcutsMapping.invalidDeviceMessage)
        }
        let result = AutomationController.shared.perform(request)
        if let msg = ShortcutsMapping.failureMessage(disabled: result == .disabled,
                                                     noTarget: result == .noTarget,
                                                     device: request.device) {
            throw ShortcutsError(message: msg)
        }
        return ShortcutsMapping.successMessage(command)
    }

    static func status(device: String?) throws -> GogglesStatusSnapshot {
        guard let request = ShortcutsMapping.request(.showWindow, device: device) else {
            throw ShortcutsError(message: ShortcutsMapping.invalidDeviceMessage)
        }
        if let msg = ShortcutsMapping.failureMessage(disabled: !AutomationPrefs.enabled(), noTarget: false, device: nil) {
            throw ShortcutsError(message: msg)
        }
        let controller = AutomationController.shared
        let count = controller.openSessions.count
        guard let s = controller.target(device: request.device) else {
            if request.device != nil {
                throw ShortcutsError(message: ShortcutsMapping.failureMessage(disabled: false, noTarget: true, device: request.device) ?? "")
            }
            return GogglesStatusSnapshot(gogglesCount: count, recording: false, fps: nil, batteryPercent: nil)
        }
        return GogglesStatusSnapshot(
            gogglesCount: count,
            recording: AutomationRecordingState.shared.isRecording(s.decodeSession),
            fps: s.coordinator.stats?.fps,
            batteryPercent: s.coordinator.batteryPercent)
    }
}

// MARK: - Intents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start recording the live goggles view.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.startRecording, device: device)))
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stop the current recording.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.stopRecording, device: device)))
    }
}

struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription("Start recording, or stop it if one is running.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.toggleRecording, device: device)))
    }
}

struct SaveReplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Instant Replay"
    static let description = IntentDescription("Save the instant-replay buffer to a clip.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.saveReplay, device: device)))
    }
}

struct TakeScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Screenshot"
    static let description = IntentDescription("Save a screenshot of the live goggles view.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.screenshot, device: device)))
    }
}

struct AddMarkerIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Marker"
    static let description = IntentDescription("Add a marker to the current recording.")
    static let openAppWhenRun = false
    @Parameter(title: "Label", description: "Marker text. Defaults to \"Marker\".")
    var label: String?
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(ShortcutsMapping.markerCommand(label: label), device: device)))
    }
}

struct StartNetworkStreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Network Stream"
    static let description = IntentDescription("Start the UDP network stream using the host and port from Settings.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.startStream, device: device)))
    }
}

struct StopNetworkStreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Network Stream"
    static let description = IntentDescription("Stop the UDP network stream.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.stopStream, device: device)))
    }
}

struct ToggleFreezeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Freeze"
    static let description = IntentDescription("Freeze or unfreeze the live view.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.toggleFreeze, device: device)))
    }
}

struct ShowWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Goggles Window"
    static let description = IntentDescription("Bring the goggles window (or the device picker) to the front.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try ShortcutsRunner.run(.showWindow, device: device)))
    }
}

/// Result of "Get Status"; each field is usable as a variable in Shortcuts.
struct GogglesStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Goggles Status")

    @Property(title: "Goggles Count") var gogglesCount: Int
    @Property(title: "Recording") var recording: Bool
    /// -1 when unknown.
    @Property(title: "FPS") var fps: Int
    /// -1 when unknown.
    @Property(title: "Battery") var battery: Int
    @Property(title: "Summary") var summary: String

    init() { gogglesCount = 0; recording = false; fps = -1; battery = -1; summary = "" }

    init(_ s: GogglesStatusSnapshot) {
        gogglesCount = s.gogglesCount
        recording = s.recording
        fps = s.fps ?? -1
        battery = s.batteryPercent ?? -1
        summary = s.summary
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(summary)") }
}

struct GetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Goggles Status"
    static let description = IntentDescription("Number of connected goggles, recording state, fps and battery level.")
    static let openAppWhenRun = false
    @Parameter(title: "Device", description: "Goggles serial number. Leave empty for the frontmost goggles.")
    var device: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<GogglesStatusEntity> & ProvidesDialog {
        let snapshot = try ShortcutsRunner.status(device: device)
        return .result(value: GogglesStatusEntity(snapshot), dialog: IntentDialog(stringLiteral: snapshot.summary))
    }
}

// MARK: - Siri / Spotlight phrases (App Shortcuts allows at most 10)

struct GogglesViewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: [
            "Start recording in \(.applicationName)", "Start \(.applicationName) recording",
        ], shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: [
            "Stop recording in \(.applicationName)", "Stop \(.applicationName) recording",
        ], shortTitle: "Stop Recording", systemImageName: "stop.circle")
        AppShortcut(intent: ToggleRecordingIntent(), phrases: [
            "Toggle recording in \(.applicationName)",
        ], shortTitle: "Toggle Recording", systemImageName: "record.circle.fill")
        AppShortcut(intent: SaveReplayIntent(), phrases: [
            "Save instant replay in \(.applicationName)", "Save replay in \(.applicationName)",
        ], shortTitle: "Save Instant Replay", systemImageName: "gobackward")
        AppShortcut(intent: TakeScreenshotIntent(), phrases: [
            "Take a screenshot in \(.applicationName)", "\(.applicationName) screenshot",
        ], shortTitle: "Take Screenshot", systemImageName: "camera")
        AppShortcut(intent: AddMarkerIntent(), phrases: [
            "Add a marker in \(.applicationName)",
        ], shortTitle: "Add Marker", systemImageName: "flag")
        AppShortcut(intent: StartNetworkStreamIntent(), phrases: [
            "Start the network stream in \(.applicationName)",
        ], shortTitle: "Start Network Stream", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: StopNetworkStreamIntent(), phrases: [
            "Stop the network stream in \(.applicationName)",
        ], shortTitle: "Stop Network Stream", systemImageName: "stop")
        AppShortcut(intent: ToggleFreezeIntent(), phrases: [
            "Freeze the view in \(.applicationName)",
        ], shortTitle: "Toggle Freeze", systemImageName: "snowflake")
        AppShortcut(intent: GetStatusIntent(), phrases: [
            "Get \(.applicationName) status",
        ], shortTitle: "Get Status", systemImageName: "info.circle")
    }
}
#endif
