import Foundation
import Darwin

/// Readiness waiting and TCP connect, run off the connection actor on a dispatch queue.
enum SocketPoller {
    struct Interest: OptionSet, Sendable {
        let rawValue: Int
        static let read = Interest(rawValue: 1)
        static let write = Interest(rawValue: 2)
    }

    private static let queue = DispatchQueue(label: "SSHKit.SocketPoller", attributes: .concurrent)

    /// Suspends until the socket is ready for `interest` or `timeoutMs` elapses.
    static func wait(fd: Int32, interest: Interest, timeoutMs: Int32) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                var p = pollfd(fd: fd, events: 0, revents: 0)
                if interest.contains(.read) { p.events |= Int16(POLLIN) }
                if interest.contains(.write) { p.events |= Int16(POLLOUT) }
                _ = poll(&p, 1, timeoutMs)
                cont.resume()
            }
        }
    }

    /// Resolves and connects; returns a non-blocking socket.
    static func connect(host: String, port: UInt16, timeoutMs: Int32 = 15_000) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            queue.async {
                do { cont.resume(returning: try blockingConnect(host: host, port: port, timeoutMs: timeoutMs)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func blockingConnect(host: String, port: UInt16, timeoutMs: Int32) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw SSHError.connectionFailed(String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(res) }
        var lastError = "no addresses"
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { lastError = String(cString: strerror(errno)); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let c = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if c == 0 { return fd }
            if errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&p, 1, timeoutMs)
                if pr == 0 { lastError = "timed out"; Darwin.close(fd); continue }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if pr > 0 && err == 0 { return fd }
                lastError = String(cString: strerror(err != 0 ? err : errno))
            } else {
                lastError = String(cString: strerror(errno))
            }
            Darwin.close(fd)
        }
        throw SSHError.connectionFailed(lastError)
    }
}
