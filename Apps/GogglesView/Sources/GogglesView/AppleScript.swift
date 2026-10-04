#if canImport(AppKit)
import AppKit

// AppleScript suite (BundleResources/GogglesView.sdef). Cocoa Scripting
// instantiates these by the `@objc` names the sdef's <cocoa class> elements
// reference, and reads the application properties via KVC on NSApplication,
// so this works from a plain SwiftPM build (no Xcode target needed). Every
// command funnels into `AutomationController.perform` -- same dispatch, same
// "Allow automation" gate as the URL scheme.

/// Base: optional `device` parameter, gate + error reporting.
class GVScriptCommand: NSScriptCommand {
    var command: AutomationCommand { .toggleRecording }

    override func performDefaultImplementation() -> Any? {
        let device = (evaluatedArguments?["device"] as? String).flatMap(AutomationURLParser.sanitizeDevice)
        if evaluatedArguments?["device"] != nil, device == nil {
            return fail(Int(errOSACantAssign), "Invalid device identifier.")
        }
        switch AutomationController.shared.perform(AutomationRequest(command: command, device: device)) {
        case .done: return nil
        case .disabled:
            return fail(Int(errAEEventNotPermitted), "Automation is turned off in GogglesView Settings > Advanced.")
        case .noTarget:
            return fail(Int(errAENoSuchObject), device == nil ? "No goggles window is open." : "No open goggles match that device.")
        }
    }

    private func fail(_ code: Int, _ message: String) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return nil
    }
}

@objc(GVStartRecordingCommand) final class GVStartRecordingCommand: GVScriptCommand {
    override var command: AutomationCommand { .startRecording }
}
@objc(GVStopRecordingCommand) final class GVStopRecordingCommand: GVScriptCommand {
    override var command: AutomationCommand { .stopRecording }
}
@objc(GVSaveReplayCommand) final class GVSaveReplayCommand: GVScriptCommand {
    override var command: AutomationCommand { .saveReplay }
}
@objc(GVTakeScreenshotCommand) final class GVTakeScreenshotCommand: GVScriptCommand {
    override var command: AutomationCommand { .screenshot }
}
@objc(GVToggleFreezeCommand) final class GVToggleFreezeCommand: GVScriptCommand {
    override var command: AutomationCommand { .toggleFreeze }
}
@objc(GVAddMarkerCommand) final class GVAddMarkerCommand: GVScriptCommand {
    override var command: AutomationCommand {
        let label = (evaluatedArguments?["label"] as? String).flatMap(AutomationURLParser.sanitizeLabel)
        return .addMarker(label: label ?? AutomationURLParser.defaultMarkerLabel)
    }
}

/// Read-only application properties (sdef <cocoa key>s). Values describe the
/// frontmost goggles window -- the same one an untargeted command acts on.
/// `missing value` when there's no window or the value isn't known yet.
extension NSApplication {
    @objc var gvGogglesCount: Int { AutomationController.shared.openSessions.count }

    @objc var gvRecording: Bool {
        guard let s = AutomationController.shared.target(device: nil) else { return false }
        return AutomationRecordingState.shared.isRecording(s.decodeSession)
    }

    @objc var gvBattery: NSNumber? {
        AutomationController.shared.target(device: nil)?.coordinator.batteryPercent.map { NSNumber(value: $0) }
    }

    @objc var gvFPS: NSNumber? {
        AutomationController.shared.target(device: nil)?.coordinator.stats.map { NSNumber(value: $0.fps) }
    }
}
#endif
