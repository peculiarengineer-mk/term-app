import Foundation
import Darwin

/// Readiness waiting and TCP connect, run off the connection actor on a dispatch queue.
enum SocketPoller {
    struct Interest: OptionSet, Sendable {
        let rawValue: Int
        static let read = Interest(rawValue: 1)
        static let write = Interest(rawValue: 2)
    }

    /// Thread-safe cancellation flag used to wake/abort `poll()` slices.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private static let queue = DispatchQueue(label: "SSHKit.SocketPoller", attributes: .concurrent)
    private static let pollSliceMs: Int64 = 50

    /// Suspends until the socket is ready for `interest`, `timeoutMs` elapses, or the wait is cancelled.
    static func wait(fd: Int32, interest: Interest, timeoutMs: Int32, cancelFlag: CancelFlag? = nil) async {
        let flag = cancelFlag ?? CancelFlag()
        if Task.isCancelled || flag.isCancelled || fd < 0 { return }
        var events: Int16 = 0
        if interest.contains(.read) { events |= Int16(POLLIN) }
        if interest.contains(.write) { events |= Int16(POLLOUT) }
        guard events != 0 else { return }
        let pollEvents = events
        let deadline = ContinuousClock.now + .milliseconds(max(0, Int(timeoutMs)))
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                queue.async {
                    if !flag.isCancelled {
                        _ = pollUntilReady(fd: fd, events: pollEvents, deadline: deadline, cancelFlag: flag)
                    }
                    cont.resume()
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Resolves and connects using a single monotonic timeout budget across all resolved addresses;
    /// returns a non-blocking socket.
    static func connect(host: String, port: UInt16, timeoutMs: Int32 = 15_000) async throws -> Int32 {
        try Task.checkCancellation()
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                queue.async {
                    if flag.isCancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        cont.resume(returning: try blockingConnect(host: host, port: port, timeoutMs: timeoutMs, cancelFlag: flag))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Polls `fd` for `events` in short slices until ready, `deadline` expires, `cancelFlag` triggers, or an error occurs.
    /// Returns `1` when ready, `0` on timeout, `-1` on poll error, or `-2` when cancelled.
    static func pollUntilReady(
        fd: Int32,
        events: Int16,
        deadline: ContinuousClock.Instant,
        cancelFlag: CancelFlag
    ) -> Int32 {
        while true {
            if cancelFlag.isCancelled { return -2 }
            let remMs = remainingMilliseconds(until: deadline)
            if remMs <= 0 { return 0 }
            let slice = Int32(min(remMs, pollSliceMs))
            var p = pollfd(fd: fd, events: events, revents: 0)
            let pr = poll(&p, 1, slice)
            if pr > 0 { return 1 }
            if pr < 0 {
                if errno == EINTR { continue }
                return -1
            }
        }
    }

    private static func remainingMilliseconds(until deadline: ContinuousClock.Instant) -> Int64 {
        let rem = deadline - ContinuousClock.now
        guard rem > .zero else { return 0 }
        let (sec, atto) = rem.components
        return sec * 1_000 + (atto + 999_999_999_999_999) / 1_000_000_000_000_000
    }

    private static func blockingConnect(
        host: String,
        port: UInt16,
        timeoutMs: Int32,
        cancelFlag: CancelFlag
    ) throws -> Int32 {
        let deadline = ContinuousClock.now + .milliseconds(max(0, Int(timeoutMs)))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        if cancelFlag.isCancelled {
            if rc == 0 { freeaddrinfo(res) }
            throw CancellationError()
        }
        guard rc == 0, let first = res else {
            throw SSHError.connectionFailed(String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(res) }

        var lastError = "no addresses"
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            if cancelFlag.isCancelled { throw CancellationError() }
            if remainingMilliseconds(until: deadline) <= 0 {
                lastError = "timed out"
                break
            }
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { lastError = String(cString: strerror(errno)); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

            let c = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if c == 0 {
                if cancelFlag.isCancelled { Darwin.close(fd); throw CancellationError() }
                return fd
            }
            if errno == EINPROGRESS || errno == EINTR {
                let pr = pollUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline, cancelFlag: cancelFlag)
                if pr == -2 { Darwin.close(fd); throw CancellationError() }
                if pr == 0 { lastError = "timed out"; Darwin.close(fd); break }
                if pr < 0 { lastError = String(cString: strerror(errno)); Darwin.close(fd); continue }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0 {
                    if cancelFlag.isCancelled { Darwin.close(fd); throw CancellationError() }
                    return fd
                }
                lastError = String(cString: strerror(err != 0 ? err : errno))
            } else {
                lastError = String(cString: strerror(errno))
            }
            Darwin.close(fd)
        }
        throw SSHError.connectionFailed(lastError)
    }
}
