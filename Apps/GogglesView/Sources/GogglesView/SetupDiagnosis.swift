import Foundation

/// Pure logic for the guided setup assistant: turns what the app can observe
/// (background service state, USB presence, claim result, video) into four
/// ordered steps with a state, one plain sentence and at most one action.
/// No UI, no I/O; `evaluate` is the single place the step logic lives.
/// Builds on `SetupChecklist.Registration` and `SetupChecklist.Reachability`.
enum SetupDiagnosis {
    enum Helper: Equatable {
        case ready, needsApproval, notRegistered, connecting, unreachable, versionMismatch, unknown

        /// Combines the SMAppService status with whether the XPC link answers.
        static func from(registration: SetupChecklist.Registration, reachability: SetupChecklist.Reachability) -> Helper {
            switch registration {
            case .requiresApproval: return .needsApproval
            case .notRegistered, .notFound: return .notRegistered
            case .unknown: return .unknown
            case .enabled:
                switch reachability {
                case .connected: return .ready
                case .connecting, .unknown: return .connecting
                case .disconnected: return .unreachable
                case .versionMismatch: return .versionMismatch
                }
            }
        }
    }

    /// Outcome of taking control of the goggles, from the connection state.
    enum Claim: Equatable { case unknown, inProgress, failed, claimed }

    enum Video: Equatable { case none, waitingForKeyframe, live }

    /// Reduces the states of all open goggles windows to one claim result.
    static func claim(from states: [GogglesUIState]) -> Claim {
        var result = Claim.unknown
        for state in states {
            switch state {
            case .handshaking, .waitingForKeyframe, .live, .stalled: return .claimed
            case .claimFailed: result = .failed
            case .claiming, .resolving: if result != .failed { result = .inProgress }
            case .noHelper, .noDevice: break
            }
        }
        return result
    }

    static func video(from states: [GogglesUIState]) -> Video {
        if states.contains(where: { $0.kind == .live }) { return .live }
        if states.contains(where: { $0.kind == .waitingForKeyframe }) { return .waitingForKeyframe }
        return .none
    }

    struct Step: Equatable, Identifiable {
        enum ID: String, CaseIterable { case helper, usb, otg, video }
        /// done = green, attention = amber (needs you, or in progress), pending = grey (waiting on an earlier step).
        enum State: Equatable { case done, attention, pending }
        enum Action: Equatable {
            case openSystemSettings, registerHelper, reconnectHelper, retryConnection

            var title: String {
                switch self {
                case .openSystemSettings: return L("Open System Settings")
                case .registerHelper: return L("Set up background service")
                case .reconnectHelper: return L("Reconnect")
                case .retryConnection: return L("Retry")
                }
            }
        }

        let id: ID
        let state: State
        let title: String
        let message: String
        /// Numbered instructions, when the step has them.
        let instructions: [String]
        /// Extra hints shown under the instructions.
        let hints: [String]
        let action: Action?
    }

    static var otgInstructions: [String] { [
        L("On the goggles: Settings > About > turn on OTG Wired Connection to Computer."),
        L("Unplug the USB-C cable, then plug it back in. The switch only takes effect after replugging."),
    ] }
    static var cableHints: [String] { [
        L("Use a USB-C cable that carries data (charge-only cables don't work) and plug it into the goggles' USB-C port."),
        L("Try another Mac port."),
    ] }
    static let shareLiveviewLabel = "Share Liveview to Mobile Device via Wi-Fi"

    private static func step(_ id: Step.ID, _ state: Step.State, _ title: String, _ message: String,
                             instructions: [String] = [], hints: [String] = [], action: Step.Action? = nil) -> Step {
        Step(id: id, state: state, title: title, message: message, instructions: instructions, hints: hints, action: action)
    }

    static func evaluate(helper: Helper, usbSeen: Bool, claim: Claim, video: Video) -> [Step] {
        let claimFailed = claim == .failed
        // A claim (or a failed claim) proves the goggles are on USB even if the registry probe missed them.
        let seen = usbSeen || claim == .claimed || claimFailed
        let helperReady = helper == .ready
        let bs = L("Background service")

        let helperStep: Step
        switch helper {
        case .ready:
            helperStep = step(.helper, .done, bs, L("The background service is approved and running."))
        case .needsApproval:
            helperStep = step(.helper, .attention, bs,
                              L("macOS is waiting for your approval. In System Settings > General > Login Items & Extensions, switch on GogglesView."),
                              action: .openSystemSettings)
        case .notRegistered:
            helperStep = step(.helper, .attention, bs,
                              L("GogglesView needs a small background service to talk to the goggles. Set it up, then approve it in System Settings."),
                              action: .registerHelper)
        case .connecting:
            helperStep = step(.helper, .attention, bs, L("Starting the background service…"))
        case .unreachable:
            helperStep = step(.helper, .attention, bs,
                              L("The background service is approved but isn't answering. Try reconnecting."),
                              action: .reconnectHelper)
        case .versionMismatch:
            helperStep = step(.helper, .attention, bs,
                              L("The background service is from a different version of GogglesView. Set it up again, or reinstall the app."),
                              action: .registerHelper)
        case .unknown:
            helperStep = step(.helper, .pending, bs, L("Checking the background service…"))
        }

        let usbStep: Step
        if claimFailed {
            usbStep = step(.usb, .attention, L("Goggles on USB"),
                           L("Your goggles are connected, but GogglesView couldn't take control of them. Another app or a macOS network adapter may be using them. Quit other goggles or capture apps, unplug and replug, then retry."),
                           hints: [L("If it keeps failing, open System Settings > Network and turn off the new network adapter macOS added for the goggles.")],
                           action: .retryConnection)
        } else if seen {
            usbStep = step(.usb, .done, L("Goggles on USB"), L("Your goggles are connected over USB."))
        } else {
            usbStep = step(.usb, .attention, L("Goggles on USB"),
                           L("No goggles found on USB yet. Check the steps below: the OTG switch, the cable, the port and that the goggles are awake."))
        }

        let otgStep: Step
        if seen {
            otgStep = step(.otg, .done, L("OTG and cable"), L("OTG is on and the cable works: the goggles show up on USB."))
        } else {
            otgStep = step(.otg, .attention, L("OTG and cable"), L("Turn on OTG on the goggles, then replug the cable."),
                           instructions: otgInstructions, hints: cableHints)
        }

        let videoStep: Step
        if !(helperReady && seen && !claimFailed) {
            videoStep = step(.video, .pending, L("Video"), L("This starts once the steps above are done."))
        } else if video == .live {
            videoStep = step(.video, .done, L("Video"), L("Video is arriving from your goggles."))
        } else {
            videoStep = step(.video, .attention, L("Video"),
                             video == .waitingForKeyframe
                                ? L("Connected, but no picture yet. Turn sharing off and on again on the goggles.")
                                : L("Start Share Liveview on the goggles."),
                             instructions: [L("On the goggles, open the shortcut menu (5D button or AR dial) and turn on '%@'. If it's already on, turn it off and on again.", shareLiveviewLabel)])
        }
        return [helperStep, usbStep, otgStep, videoStep]
    }

    static func isComplete(_ steps: [Step]) -> Bool {
        !steps.isEmpty && steps.allSatisfy { $0.state == .done }
    }

    /// One line for Settings: all good, or the first step that needs attention.
    static func healthLine(_ steps: [Step]) -> String {
        if isComplete(steps) { return L("Everything is working.") }
        guard let step = steps.first(where: { $0.state != .done }) else { return L("Checking…") }
        return "\(step.title): \(step.message)"
    }
}
