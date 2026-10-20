import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
#endif

/// "Preview on this Mac" can be switched off so the picture is drawn on the HDMI program outputs only,
/// which lightens the Mac. It never applies unless an output window is actually on screen.
enum PreviewPolicy {
    static let hdmiOnlyKey = "previewHdmiOnly"
    static func previewActive(hdmiOnly: Bool, outputsShown: Bool) -> Bool { !(hdmiOnly && outputsShown) }
}

/// Current answer, cheap to read per frame from the decode threads; written on the main thread.
final class PreviewState: ObservableObject {
    static let shared = PreviewState()
    @Published private(set) var active = true
    private let lock = NSLock()
    private var flag = true

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return flag }

    func update(hdmiOnly: Bool, outputsShown: Bool) {
        let on = PreviewPolicy.previewActive(hdmiOnly: hdmiOnly, outputsShown: outputsShown)
        lock.lock(); flag = on; lock.unlock()
        if on != active { active = on }
    }
}

#if canImport(SwiftUI) && canImport(AppKit)
/// The goggles video, covered by a plain placeholder while the preview is off (the layer stays attached, it just gets no frames).
struct PreviewVideoView: View {
    let session: DecodeSession
    var isSecondary = false
    @ObservedObject private var state = PreviewState.shared

    var body: some View {
        ZStack {
            GogglesVideoView(session: session, isSecondary: isSecondary)
            if !state.active {
                ZStack {
                    Color(white: 0.1)
                    VStack(spacing: 4) {
                        Text(verbatim: L("Preview off, showing on HDMI only")).font(.headline)
                        Text(verbatim: L("To bring it back: Goggles menu > Preview on this Mac."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white).multilineTextAlignment(.center).minimumScaleFactor(0.5).padding(8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Preview off, showing on HDMI only"))
            }
        }
    }
}
#endif
