import Foundation
import CoreMediaIO

// Entry point of the `GogglesCamera` system extension: a plain Mach-O launched by the system-extension
// machinery. Publish the provider and keep the process alive on its run loop.

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
