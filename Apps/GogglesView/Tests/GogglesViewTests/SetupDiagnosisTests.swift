import Testing
import Foundation
@testable import GogglesView

struct SetupDiagnosisTests {
    typealias D = SetupDiagnosis

    private func states(_ steps: [D.Step]) -> [D.Step.State] { steps.map(\.state) }

    @Test func everythingGoodIsComplete() {
        let s = D.evaluate(helper: .ready, usbSeen: true, claim: .claimed, video: .live)
        #expect(states(s) == [.done, .done, .done, .done])
        #expect(D.isComplete(s))
        #expect(s.allSatisfy { $0.action == nil })
    }

    @Test func fourStepsInOrder() {
        let s = D.evaluate(helper: .ready, usbSeen: false, claim: .unknown, video: .none)
        #expect(s.map(\.id) == [.helper, .usb, .otg, .video])
    }

    @Test func needsApprovalOffersSystemSettings() {
        let s = D.evaluate(helper: .needsApproval, usbSeen: true, claim: .unknown, video: .none)
        #expect(s[0].state == .attention)
        #expect(s[0].action == .openSystemSettings)
        #expect(D.Step.Action.openSystemSettings.title == "Open System Settings")
        // USB is detected independently of the service.
        #expect(s[1].state == .done)
        #expect(s[3].state == .pending)
    }

    @Test func notRegisteredOffersSetup() {
        let s = D.evaluate(helper: .notRegistered, usbSeen: false, claim: .unknown, video: .none)
        #expect(s[0].action == .registerHelper)
        #expect(!D.isComplete(s))
    }

    @Test func unreachableOffersReconnectAndMismatchOffersSetup() {
        #expect(D.evaluate(helper: .unreachable, usbSeen: true, claim: .unknown, video: .none)[0].action == .reconnectHelper)
        #expect(D.evaluate(helper: .versionMismatch, usbSeen: true, claim: .unknown, video: .none)[0].action == .registerHelper)
        #expect(D.evaluate(helper: .connecting, usbSeen: true, claim: .unknown, video: .none)[0].action == nil)
        #expect(D.evaluate(helper: .unknown, usbSeen: true, claim: .unknown, video: .none)[0].state == .pending)
    }

    @Test func nothingOnUSBShowsOTGChecklist() {
        let s = D.evaluate(helper: .ready, usbSeen: false, claim: .unknown, video: .none)
        #expect(s[1].state == .attention)
        #expect(s[2].state == .attention)
        #expect(s[2].instructions == D.otgInstructions)
        #expect(s[2].instructions[0].contains("Settings > About > turn on OTG Wired Connection to Computer."))
        #expect(s[2].hints == D.cableHints)
        #expect(s[3].state == .pending)
    }

    @Test func seenButClaimFailedIsDistinctFromNothingOnUSB() {
        let s = D.evaluate(helper: .ready, usbSeen: true, claim: .failed, video: .none)
        #expect(s[1].state == .attention)
        #expect(s[1].action == .retryConnection)
        #expect(s[1].message.contains("couldn't take control"))
        #expect(s[2].state == .done)
        #expect(s[3].state == .pending)
        let none = D.evaluate(helper: .ready, usbSeen: false, claim: .unknown, video: .none)
        #expect(none[1].message != s[1].message)
    }

    @Test func claimedImpliesSeenEvenIfProbeMissed() {
        let s = D.evaluate(helper: .ready, usbSeen: false, claim: .claimed, video: .none)
        #expect(s[1].state == .done)
        #expect(s[2].state == .done)
    }

    @Test func videoStepWaitsThenGoesGreen() {
        let waiting = D.evaluate(helper: .ready, usbSeen: true, claim: .claimed, video: .none)
        #expect(waiting[3].state == .attention)
        #expect(waiting[3].instructions[0].contains("Share Liveview to Mobile Device via Wi-Fi"))
        #expect(waiting[3].instructions[0].contains("5D button or AR dial"))
        #expect(!D.isComplete(waiting))
        let noKey = D.evaluate(helper: .ready, usbSeen: true, claim: .claimed, video: .waitingForKeyframe)
        #expect(noKey[3].state == .attention)
        #expect(D.isComplete(D.evaluate(helper: .ready, usbSeen: true, claim: .claimed, video: .live)))
    }

    @Test func videoNeverGreenWhileServiceNotReady() {
        let s = D.evaluate(helper: .needsApproval, usbSeen: true, claim: .claimed, video: .live)
        #expect(s[3].state == .pending)
        #expect(!D.isComplete(s))
    }

    @Test func everyCombinationYieldsFourSteps() {
        let helpers: [D.Helper] = [.ready, .needsApproval, .notRegistered, .connecting, .unreachable, .versionMismatch, .unknown]
        let claims: [D.Claim] = [.unknown, .inProgress, .failed, .claimed]
        let videos: [D.Video] = [.none, .waitingForKeyframe, .live]
        for h in helpers { for usb in [true, false] { for c in claims { for v in videos {
            let s = D.evaluate(helper: h, usbSeen: usb, claim: c, video: v)
            #expect(s.count == 4)
            #expect(s.allSatisfy { !$0.message.isEmpty && !$0.message.contains("—") })
            if D.isComplete(s) { #expect(h == .ready && v == .live && c != .failed) }
        } } } }
    }

    @Test func helperFromRegistrationAndReachability() {
        typealias H = D.Helper
        #expect(H.from(registration: .requiresApproval, reachability: .connected) == .needsApproval)
        #expect(H.from(registration: .notRegistered, reachability: .disconnected) == .notRegistered)
        #expect(H.from(registration: .notFound, reachability: .unknown) == .notRegistered)
        #expect(H.from(registration: .unknown, reachability: .connected) == .unknown)
        #expect(H.from(registration: .enabled, reachability: .connected) == .ready)
        #expect(H.from(registration: .enabled, reachability: .connecting) == .connecting)
        #expect(H.from(registration: .enabled, reachability: .unknown) == .connecting)
        #expect(H.from(registration: .enabled, reachability: .disconnected) == .unreachable)
        #expect(H.from(registration: .enabled, reachability: .versionMismatch) == .versionMismatch)
    }

    @Test func claimAndVideoFromStates() {
        #expect(D.claim(from: []) == .unknown)
        #expect(D.claim(from: [.noDevice]) == .unknown)
        #expect(D.claim(from: [.claiming]) == .inProgress)
        #expect(D.claim(from: [.claimFailed(reason: "x")]) == .failed)
        #expect(D.claim(from: [.claimFailed(reason: "x"), .live]) == .claimed)
        #expect(D.claim(from: [.handshaking(elapsedSeconds: 1)]) == .claimed)
        #expect(D.video(from: [.live]) == .live)
        #expect(D.video(from: [.stalled, .waitingForKeyframe]) == .waitingForKeyframe)
        #expect(D.video(from: [.handshaking(elapsedSeconds: 0)]) == .none)
        #expect(D.video(from: []) == .none)
    }

    @Test func accessibilityLabelNamesStateInWords() {
        let t = AccessibilityLabels.setupStep(number: 2, of: 4, title: "Goggles on USB", state: .attention, message: "No goggles found.")
        #expect(t == "Step 2 of 4, Goggles on USB, needs attention. No goggles found.")
        #expect(AccessibilityLabels.setupStep(number: 1, of: 4, title: "T", state: .done, message: "m").contains("done"))
        #expect(AccessibilityLabels.setupStep(number: 4, of: 4, title: "T", state: .pending, message: "m").contains("waiting"))
    }
}
