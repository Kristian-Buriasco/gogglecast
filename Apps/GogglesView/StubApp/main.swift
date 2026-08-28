// Task 2.3 stub app entry point.
//
// This is NOT the real SwiftUI app (that's Task 3.x's job). It exists solely
// so `SMAppService.daemon(plistName:).status` can be checked from code that is
// actually running inside `GogglesView.app` -- `SMAppService` resolves the
// calling process's own bundle, so a standalone script outside the bundle
// cannot be used to verify bundle/plist discoverability.
//
// Usage (from inside the assembled .app's Contents/MacOS/):
//   ./GogglesView --check-daemon-status
//
// Prints the SMAppService.daemon(plistName:) status for the helper's launchd
// plist and exits. Does NOT call .register() -- that is Task 2.4's job.

import Foundation
import ServiceManagement

let plistName = "com.kburiasco.gogglesview.helper.plist"

let args = CommandLine.arguments
guard args.contains("--check-daemon-status") else {
    print("GogglesView stub (Task 2.3). Pass --check-daemon-status to check SMAppService.daemon status.")
    exit(0)
}

let service = SMAppService.daemon(plistName: plistName)
let status = service.status

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

print("plistName: \(plistName)")
print("SMAppService.daemon(plistName:).status = \(describe(status)) (rawValue=\(status.rawValue))")
