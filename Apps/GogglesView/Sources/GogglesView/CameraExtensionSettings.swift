#if canImport(AppKit)
import SwiftUI

/// Runs the camera extension activation for the Settings button; the installer must stay alive until macOS answers.
final class CameraExtensionController: ObservableObject {
    static let shared = CameraExtensionController()
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    private let installer = CameraExtensionInstaller()

    func enable() {
        busy = true
        status = L("Waiting for your approval in System Settings > General > Login Items & Extensions > Camera Extensions.")
        installer.install { [weak self] ok in
            DispatchQueue.main.async {
                self?.busy = false
                self?.status = ok ? L("Enabled. Choose DJI Goggles 3 as a video source in OBS.")
                                  : L("The camera could not be enabled. Check System Settings > General > Login Items & Extensions.")
            }
        }
    }
}

/// Settings > Integrations > Virtual camera.
struct CameraExtensionSettingsSection: View {
    @ObservedObject private var camera = CameraExtensionController.shared

    var body: some View {
        SettingsGroup("Virtual camera",
                      info: "Adds a camera named DJI Goggles 3 that OBS and other apps can use as a video source. macOS asks you to approve it once. GogglesView has to be running with the goggles live, because the picture comes from the app's helper.") {
            SettingsRow("Camera extension", help: camera.status.isEmpty ? nil : LocalizedStringKey(camera.status)) {
                Button("Enable virtual camera") { camera.enable() }.disabled(camera.busy)
            }
        }
    }
}
#endif
