import Foundation
import GogglesXPC

/// Task 2.2: accepts every incoming `NSXPCConnection` on the Mach service
/// listener, wires up `exportedInterface`/`exportedObject`
/// (`GogglesHelperProtocol`, served by the shared `HelperService`) and
/// `remoteObjectInterface` (`GogglesClientProtocol`, for calling back into
/// each subscriber), then resumes it. One `HelperService` instance is
/// shared across every connection -- it's the subscriber registry itself,
/// not per-connection state.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GogglesHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: GogglesClientProtocol.self)

        // Captured weakly: the connection itself owns this closure, so a
        // strong capture of `newConnection` here would be a retain cycle
        // (connection -> handler -> connection) that keeps every past
        // connection alive forever.
        newConnection.invalidationHandler = { [weak service, weak newConnection] in
            guard let service, let newConnection else { return }
            Logging.xpc.info("connection invalidated")
            service.unregisterConnection(newConnection)
        }
        newConnection.interruptionHandler = {
            Logging.xpc.info("connection interrupted (remote process likely crashed or force-quit)")
        }

        service.registerConnection(newConnection)
        newConnection.resume()
        Logging.xpc.info("accepted new XPC connection")
        return true
    }
}
