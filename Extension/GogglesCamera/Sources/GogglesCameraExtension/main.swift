import Foundation
import CoreMediaIO

// ─────────────────────────────────────────────────────────────────────────
// Task 4.1 (Phase 4 gate spike). Entry point for the `GogglesCamera`
// system extension bundle. A `CMIOExtension` runs as a plain Mach-O
// executable launched by the system-extension machinery (not an in-process
// App Extension with an `NSExtensionPrincipalClass`) -- this `main.swift`
// is that executable's whole lifecycle: stand up the do-nothing
// provider/device/stream skeleton (`ProviderSource.swift`), start the
// CoreMediaIO extension machinery, attempt the one Mach-lookup spike this
// task exists to answer (`HelperSpikeConnector.swift`), then keep the
// process alive on its run loop the way every CMIOExtension sample does.
//
// THROWAWAY: this file, and this whole target, exists only to answer
// "can a sandboxed CMIOExtension reach the helper's Mach service." Task
// 4.2 replaces this with the real camera device.
// ─────────────────────────────────────────────────────────────────────────

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

Logging.spike.info("SPIKE: GogglesCameraExtension started, CMIOExtensionProvider service running, attempting helper connection...")
providerSource.helperConnector.connect()

CFRunLoopRun()
