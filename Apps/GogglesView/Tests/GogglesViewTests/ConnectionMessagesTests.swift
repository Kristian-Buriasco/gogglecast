import Testing
import Foundation
@testable import GogglesView

struct ConnectionMessagesTests {
    typealias M = ConnectionMessages

    @Test func progressStatesSayConnecting() {
        for s in [GogglesUIState.claiming, .resolving, .handshaking(elapsedSeconds: 3)] {
            let m = M.message(for: s)
            #expect(m?.headline == "Connecting to your goggles…")
            #expect(m?.showsProgress == true)
            #expect(m?.detail == nil)
        }
    }

    @Test func handshakeHintAppearsAfterFifteenSeconds() {
        #expect(M.message(for: .handshaking(elapsedSeconds: 14))?.detail == nil)
        #expect(M.message(for: .handshaking(elapsedSeconds: 15))?.detail == "Make sure live view is on, or unplug and replug the goggles.")
    }

    @Test func claimFailedShowsPlainReasonText() {
        let m = M.message(for: .claimFailed(reason: GogglesDiagnostics.interfaceClaimFailed))
        #expect(m?.headline.hasPrefix("Couldn't take control of the goggles.") == true)
        #expect(m?.headline.contains("press Retry") == true)
    }

    @Test func stalledAndNoHelperText() {
        #expect(M.message(for: .stalled)?.headline == "No video from the goggles. Check the cable and that the goggles are awake and on live view. Reconnecting…")
        #expect(M.message(for: .noHelper(reason: nil))?.headline == "The background service isn't set up yet.")
        #expect(M.message(for: .noHelper(reason: "protocol 1 vs 2"))?.detail?.contains("different version") == true)
    }

    @Test func liveAndWaitingHaveNoGenericOverlay() {
        #expect(M.message(for: .live) == nil)
        #expect(M.message(for: .waitingForKeyframe) == nil)
        #expect(M.waitingTitle == "Waiting for the first picture from your goggles")
        #expect(M.askResend == "Ask the goggles to resend")
    }

    @Test func failedStatesOfferRecoveryActions() {
        for k in [GogglesUIStateKind.noHelper, .stalled, .waitingForKeyframe, .claimFailed] {
            #expect(M.offersRecoveryActions(k))
        }
        #expect(!M.offersRecoveryActions(.live))
        #expect(!M.offersRecoveryActions(.handshaking))
    }

    @Test func noUserFacingTextUsesDeveloperWording() {
        let states: [GogglesUIState] = [.noHelper(reason: nil), .noDevice, .claiming, .resolving, .handshaking(elapsedSeconds: 20),
                                        .claimFailed(reason: GogglesDiagnostics.arpTimeout), .stalled]
        for s in states {
            let text = [M.message(for: s)?.headline, M.message(for: s)?.detail, M.shortStatus(for: s)].compactMap { $0 }.joined(separator: " ")
            for bad in ["helper", "Claiming", "Handshaking", "Resolving", "ARP", "RNDIS", "—"] {
                #expect(!text.contains(bad), "\(s) contains \(bad)")
            }
        }
    }

    @Test func closePromptOnlyWhileRunning() {
        #expect(M.closePrompt(recording: false, streaming: false) == nil)
        #expect(M.closePrompt(recording: true, streaming: false) == "Recording is running. Hide the window and keep recording, or stop and disconnect?")
        #expect(M.closePrompt(recording: false, streaming: true)?.hasPrefix("Streaming is running.") == true)
        #expect(M.closePrompt(recording: true, streaming: true)?.hasPrefix("Recording and streaming are running.") == true)
    }

    @Test func plainRegistrationStatus() {
        #expect(HelperRegistration.plainDescription(.requiresApproval) == "Waiting for your approval in System Settings")
        #expect(!HelperRegistration.plainDescription(.enabled).contains("enabled"))
    }

    @Test func traceKeepsRecentLines() {
        let t = ConnectionTrace()
        for i in 0..<(ConnectionTrace.maxLines + 5) { t.record("e\(i)") }
        #expect(t.text.split(separator: "\n").count == ConnectionTrace.maxLines)
        #expect(t.text.contains("e\(ConnectionTrace.maxLines + 4)"))
    }
}
