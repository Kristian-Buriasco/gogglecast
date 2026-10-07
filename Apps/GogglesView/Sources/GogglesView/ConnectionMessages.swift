import Foundation

/// Plain-language text for each connection state. Pure and UI-free so the
/// wording is unit-tested. Technical detail (raw helper states, error types)
/// stays in the logs and in `ConnectionTrace`, which the Diagnostics copy includes.
enum ConnectionMessages {
    /// After this many seconds of handshaking the hint about live view is added.
    static let handshakeHintAfterSeconds = 15

    static let connecting = "Connecting to your goggles…"
    static let handshakeHint = "Make sure live view is on, or unplug and replug the goggles."
    static let noDevice = "Connect your Goggles 3 with USB-C"
    static let noDeviceDetail = "Use a USB-C cable that carries data and plug it into the goggles' USB-C port."
    static let stalled = "No video from the goggles. Check the cable and that the goggles are awake and on live view. Reconnecting…"
    static let noHelper = "The background service isn't set up yet."
    static let noHelperDetail = "GogglesView needs a small background service to talk to the goggles over USB. The setup assistant walks you through approving it."
    static let noHelperMismatchDetail = "The background service is from a different version of GogglesView. Set it up again in the setup assistant, or reinstall the app."
    static let waitingTitle = "Waiting for the first picture from your goggles"
    static let waitingBody = "The goggles only send a starting frame when live sharing starts. On the goggles, open the shortcut menu (5D button) and turn 'Share Liveview to Mobile Device via Wi-Fi' off and on again."
    static let askResend = "Ask the goggles to resend"
    static let askResendSent = "Requested"
    static let askResendCaveat = "This often doesn't help. Turning sharing off and on again on the goggles is the reliable fix."

    /// Headline plus optional second line for the big centered message.
    struct Message: Equatable {
        let headline: String
        let detail: String?
        let showsProgress: Bool
    }

    /// `nil` when live (no overlay) or for the waiting card, which has its own view.
    static func message(for state: GogglesUIState) -> Message? {
        switch state {
        case .noHelper(let reason):
            return Message(headline: noHelper, detail: reason == nil ? noHelperDetail : noHelperMismatchDetail, showsProgress: false)
        case .noDevice:
            return Message(headline: noDevice, detail: noDeviceDetail, showsProgress: false)
        case .claiming, .resolving:
            return Message(headline: connecting, detail: nil, showsProgress: true)
        case .handshaking(let seconds):
            return Message(headline: connecting, detail: seconds >= handshakeHintAfterSeconds ? handshakeHint : nil, showsProgress: true)
        case .claimFailed(let reason):
            return Message(headline: reason, detail: nil, showsProgress: false)
        case .stalled:
            return Message(headline: stalled, detail: nil, showsProgress: false)
        case .waitingForKeyframe, .live:
            return nil
        }
    }

    /// States that should offer Retry, Copy diagnostics and the setup assistant.
    static func offersRecoveryActions(_ kind: GogglesUIStateKind) -> Bool {
        switch kind {
        case .noHelper, .noDevice, .claimFailed, .waitingForKeyframe, .stalled: return true
        case .claiming, .resolving, .handshaking, .live: return false
        }
    }

    /// Question shown when the red close button is pressed while recording or
    /// streaming. nil when nothing is running (the window just hides).
    static func closePrompt(recording: Bool, streaming: Bool) -> String? {
        switch (recording, streaming) {
        case (false, false): return nil
        case (true, false): return "Recording is running. Hide the window and keep recording, or stop and disconnect?"
        case (false, true): return "Streaming is running. Hide the window and keep streaming, or stop and disconnect?"
        case (true, true): return "Recording and streaming are running. Hide the window and keep them running, or stop and disconnect?"
        }
    }

    /// Menu bar, status pill and mini controls.
    static func shortStatus(for state: GogglesUIState) -> String {
        switch state {
        case .noHelper: return "Background service not set up"
        case .noDevice: return "No goggles connected"
        case .claiming, .resolving, .handshaking: return "Connecting…"
        case .claimFailed: return "Can't connect, open GogglesView"
        case .waitingForKeyframe: return "Waiting for video, check goggles live view"
        case .live: return "Live"
        case .stalled: return "No video, reconnecting…"
        }
    }
}

/// Short rolling record of raw connection events (technical detail the user
/// doesn't see). Included in the Diagnostics copy.
final class ConnectionTrace: @unchecked Sendable {
    static let shared = ConnectionTrace()
    private let lock = NSLock()
    private var lines: [String] = []
    static let maxLines = 60

    func record(_ line: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lines.append("\(ConnectionTrace.stamp(date)) \(line)")
        if lines.count > ConnectionTrace.maxLines { lines.removeFirst(lines.count - ConnectionTrace.maxLines) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? "(no events yet)" : lines.joined(separator: "\n")
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
