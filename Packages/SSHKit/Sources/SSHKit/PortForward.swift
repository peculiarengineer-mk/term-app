import Foundation
import Darwin

/// User-configured rule for SSH local port forwarding (`-L`).
public struct PortForwardRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var localPort: UInt16
    public var remoteHost: String
    public var remotePort: UInt16

    public init(
        id: UUID = UUID(),
        name: String = "",
        localPort: UInt16,
        remoteHost: String = "127.0.0.1",
        remotePort: UInt16
    ) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    public var summary: String {
        "127.0.0.1:\(localPort) → \(remoteHost):\(remotePort)"
    }
}

/// A live local port forward bound on `127.0.0.1` for an active `SSHConnection`.
public struct ActivePortForward: Equatable, Identifiable, Sendable {
    public var id: UUID { rule.id }
    public let rule: PortForwardRule
    public let boundLocalPort: UInt16

    public init(rule: PortForwardRule, boundLocalPort: UInt16) {
        self.rule = rule
        self.boundLocalPort = boundLocalPort
    }

    public var localURL: URL? {
        URL(string: "http://127.0.0.1:\(boundLocalPort)")
    }
}

enum LocalForwardSocket {
    /// Creates, binds, and listens on a non-blocking IPv4 TCP socket at `127.0.0.1:port`.
    static func bindAndListen(port: UInt16) throws -> (fd: Int32, boundPort: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SSHError.channelFailed("forward socket failed: \(SocketPoller.errorString(for: errno))")
        }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRc == 0 else {
            let msg = SocketPoller.errorString(for: errno)
            Darwin.close(fd)
            throw SSHError.channelFailed("bind 127.0.0.1:\(port) failed: \(msg)")
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let msg = SocketPoller.errorString(for: errno)
            Darwin.close(fd)
            throw SSHError.channelFailed("listen failed: \(msg)")
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRc = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        guard nameRc == 0 else {
            let msg = SocketPoller.errorString(for: errno)
            Darwin.close(fd)
            throw SSHError.channelFailed("getsockname failed: \(msg)")
        }

        return (fd, UInt16(bigEndian: boundAddr.sin_port))
    }

    enum AcceptResult {
        case accepted(fd: Int32, sourcePort: UInt16)
        case wouldBlock
        case error
    }

    /// Accepts one non-blocking client connection from `listenFd`.
    static func acceptNonBlocking(listenFd: Int32, fallbackPort: UInt16) -> AcceptResult {
        while true {
            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &clientLen)
                }
            }
            if clientFd < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
                return .error
            }

            var one: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(clientFd, F_GETFL)
            if flags >= 0 {
                _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
            }

            var sourcePort = fallbackPort
            if clientAddr.ss_family == sa_family_t(AF_INET) {
                withUnsafePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        let p = UInt16(bigEndian: sin.pointee.sin_port)
                        if p > 0 { sourcePort = p }
                    }
                }
            }
            return .accepted(fd: clientFd, sourcePort: sourcePort)
        }
    }
}

/// Bounded-overhead FIFO byte buffer for bidirectional port-forward pumping.
struct ForwardPipeBuffer {
    private(set) var storage = Data()
    private(set) var offset = 0

    var availableCount: Int { storage.count - offset }
    var isEmpty: Bool { offset >= storage.count }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        if offset >= storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        }
        storage.append(contentsOf: bytes)
    }

    mutating func consume(_ count: Int) {
        offset += count
        if offset >= storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= 32 * 1024 {
            storage.removeFirst(offset)
            offset = 0
        }
    }

    func withReadableBytes<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        storage.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                var zero: UInt8 = 0
                return body(&zero, 0)
            }
            return body(base.assumingMemoryBound(to: UInt8.self) + offset, storage.count - offset)
        }
    }
}
