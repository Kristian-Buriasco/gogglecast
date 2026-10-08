import AppKit
import SwiftUI

/// Toolbar button for the burn-in recording (⇧⌘B). Independent of the
/// passthrough record button; both can run at once.
struct BurnInRecordControl: View {
    let session: DecodeSession
    var isLive: Bool
    /// Called on the main queue while recording to feed the stats text.
    var info: () -> BurnInInfo = { BurnInInfo() }

    @StateObject private var recorder = BurnInRecorder()

    var body: some View {
        HStack(spacing: 4) {
            if recorder.isRecording {
                Text(Self.formatElapsed(recorder.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            if let err = recorder.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Button { recorder.isRecording ? stop(wait: false) : start() } label: {
                Image(systemName: recorder.isRecording ? "flame.fill" : "flame")
                    .foregroundStyle(recorder.isRecording ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isLive && !recorder.isRecording)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .help(helpText)
            .accessibilityLabel(recorder.isRecording ? L("Stop burn-in recording") : L("Start burn-in recording"))
            .accessibilityValue(AccessibilityLabels.recordState(isRecording: recorder.isRecording, elapsed: recorder.isRecording ? Self.formatElapsed(recorder.elapsed) : nil))
            .accessibilityHint("Records a re-encoded copy with the logo and text burned in")
            .accessibilityIdentifier("burnInRecordButton")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            stop(wait: true)
        }
    }

    private var helpText: String {
        if recorder.isRecording {
            return L("Stop burn-in recording (⇧⌘B)") + (recorder.droppedFrames > 0 ? " — " + L("%lld frames dropped", recorder.droppedFrames) : "")
        }
        return L("Record with logo/text burned in (re-encoded) (⇧⌘B)")
    }

    private func start() {
        session.addConsumer(recorder)
        do {
            try recorder.start(info: info)
        } catch {
            session.removeConsumer(recorder)
        }
    }

    private func stop(wait: Bool) {
        guard recorder.isRecording else { return }
        session.removeConsumer(recorder)
        let sem = DispatchSemaphore(value: 0)
        recorder.stop { url in
            if let url {
                NotificationCenter.default.post(name: .gogglesRecordingStopped, object: nil, userInfo: ["path": url.path])
            }
            sem.signal()
        }
        if wait { _ = sem.wait(timeout: .now() + 3) }
    }

    static func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
