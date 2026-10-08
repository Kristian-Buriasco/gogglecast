import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum UDPSocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case badAddress(String)
    public var description: String {
        switch self {
        case .system(let what, let code):
            #if os(Windows)
            return "\(what): WinSock error \(code)"
            #else
            return "\(what): \(String(cString: strerror(code)))"
            #endif
        case .badAddress(let a): return "bad IPv4 address '\(a)'"
        }
    }
}

#if os(Windows)
/// Minimal blocking IPv4 UDP socket (WinSock), connected to one peer.
public final class UDPSocket {
    private let handle: SOCKET

    private static let startup: Void = {
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
    }()

    public init(bind localAddress: String?, localPort: UInt16, peer: String, peerPort: UInt16) throws {
        _ = Self.startup
        handle = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP.rawValue))
        guard handle != INVALID_SOCKET else { throw UDPSocketError.system("socket", WSAGetLastError()) }
        var big: Int32 = 4 * 1024 * 1024
        _ = withUnsafePointer(to: &big) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                setsockopt(handle, SOL_SOCKET, SO_RCVBUF, $0, Int32(MemoryLayout<Int32>.size))
            }
        }
        var local = try Self.address(localAddress ?? "0.0.0.0", port: localPort)
        let b = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard b == 0 else { closesocket(handle); throw UDPSocketError.system("bind", WSAGetLastError()) }
        var remote = try Self.address(peer, port: peerPort)
        let c = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard c == 0 else { closesocket(handle); throw UDPSocketError.system("connect", WSAGetLastError()) }
    }

    deinit { closesocket(handle) }

    private static func address(_ text: String, port: UInt16) throws -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, text, &a.sin_addr) == 1 else { throw UDPSocketError.badAddress(text) }
        return a
    }

    public func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            raw.withMemoryRebound(to: CChar.self) { _ = WinSDK.send(handle, $0.baseAddress, Int32($0.count), 0) }
        }
    }

    public func receive(timeoutMs: Int32) -> Data? {
        var p = WSAPOLLFD(fd: handle, events: Int16(POLLRDNORM), revents: 0)
        guard WSAPoll(&p, 1, timeoutMs) > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 65_536)
        let n = recv(handle, &buf, Int32(buf.count), 0)
        guard n > 0 else { return nil }
        return Data(buf[0..<Int(n)].map { UInt8(bitPattern: $0) })
    }
}
#else
/// Minimal blocking IPv4 UDP socket (POSIX), connected to one peer.
public final class UDPSocket {
    private let fd: Int32

    public init(bind localAddress: String?, localPort: UInt16, peer: String, peerPort: UInt16) throws {
        #if canImport(Glibc) || canImport(Musl)
        let dgram = Int32(SOCK_DGRAM.rawValue)
        #else
        let dgram = SOCK_DGRAM
        #endif
        fd = socket(AF_INET, dgram, 0)
        guard fd >= 0 else { throw UDPSocketError.system("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var big: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))

        var local = try Self.address(localAddress ?? "0.0.0.0", port: localPort)
        let b = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard b == 0 else { close(fd); throw UDPSocketError.system("bind", errno) }

        var remote = try Self.address(peer, port: peerPort)
        let c = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard c == 0 else { close(fd); throw UDPSocketError.system("connect", errno) }
    }

    deinit { close(fd) }

    private static func address(_ text: String, port: UInt16) throws -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, text, &a.sin_addr) == 1 else { throw UDPSocketError.badAddress(text) }
        return a
    }

    public func send(_ data: Data) {
        _ = data.withUnsafeBytes { Foundation.send(fd, $0.baseAddress, data.count, 0) }
    }

    /// Waits up to `timeoutMs` for a datagram. Returns nil on timeout or error.
    public func receive(timeoutMs: Int32) -> Data? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 65_536)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf[0..<n]) : nil
    }
}
#endif
