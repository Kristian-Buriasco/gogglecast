import Foundation

/// `GogglesHelper --xpc`: starts an `NSXPCListener` on `machServiceName`
/// (design §5.5) and blocks the process alive via `dispatchMain()` --
/// consistent with `installSigtermHandler`'s `DispatchSourceSignal` on the
/// main queue (`SignalHandling.swift`), which is what actually lets a
/// `launchd`-delivered `SIGTERM` release USB interfaces cleanly before
/// this function's caller ever returns.
func runXPCMode() {
    Logging.xpc.info("starting XPC listener on Mach service '\(machServiceName, privacy: .public)'")
    FileHandle.standardError.write(Data(
        "[GogglesHelper] Starting XPC listener on Mach service '\(machServiceName)'...\n".utf8
    ))

    let service = HelperService()
    let delegate = HelperListenerDelegate(service: service)
    let listener = NSXPCListener(machServiceName: machServiceName)
    listener.delegate = delegate
    listener.resume()

    installSigtermHandler()

    Logging.xpc.info("listener resumed, entering run loop")
    dispatchMain()
}
