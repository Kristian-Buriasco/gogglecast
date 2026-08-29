import Foundation
import SystemExtensions

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1: minimal `OSSystemExtensionRequest` installer for the throwaway
// `GogglesCamera` spike bundle (`Extension/GogglesCamera`). Deliberately
// small -- one activation request, one delegate that logs every callback
// and calls a completion closure once, no retry/replacement-action policy
// beyond the required delegate methods. Not meant to survive into Task 4.2
// unchanged (a real installer needs a proper UI-driven retry/upgrade story
// -- design §8.5).
// ─────────────────────────────────────────────────────────────────────────

/// The extension's `CFBundleIdentifier` (`Extension/GogglesCamera/BundleResources/Info.plist`).
let cameraExtensionBundleIdentifier = "com.kburiasco.gogglesview.camera"

final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    private var completion: ((Bool) -> Void)?

    func install(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        print("--install-camera-extension: submitting OSSystemExtensionRequest.activationRequest for \(cameraExtensionBundleIdentifier)...")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: cameraExtensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("--install-camera-extension: didFinishWithResult: \(result.rawValue) (\(String(describing: result)))")
        completion?(result == .completed)
        completion = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("--install-camera-extension: didFailWithError: \(error)")
        completion?(false)
        completion = nil
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("--install-camera-extension: requestNeedsUserApproval -- approve in System Settings > General > Login Items & Extensions > Camera Extensions, or (unsigned/dev builds) this is the point where `systemextensionsctl developer on` + reboot into developer mode is required first (design §8.5). See docs/dev-setup.md.")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        print("--install-camera-extension: actionForReplacingExtension: existing=\(existing.bundleVersion) new=\(ext.bundleVersion) -- replacing")
        return .replace
    }
}
