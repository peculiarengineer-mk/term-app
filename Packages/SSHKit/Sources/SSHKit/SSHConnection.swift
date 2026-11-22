import Foundation
import Darwin
import CLibSSH2

/// Bridges the synchronous libssh2 keyboard-interactive callback to an async handler.
/// The actor runs on a dedicated dispatch queue (not the cooperative pool), and the wait is
/// bounded and can be cancelled from `close()` / task cancellation without entering the actor.
// @unchecked Sendable: all mutable state is guarded by `lock`; each round's semaphore is a lock-guarded snapshot, signalled outside the lock.
private final class KbdContext: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Prompt) async -> [String])?
    private var cancelled = false
    // Per-round state: a fresh semaphore and generation per `ask`, so a late answer from a
    // timed-out round can never satisfy (or leak its answers into) the next round.
    private var generation = 0
    private var sem: DispatchSemaphore?
    private var answer: [String] = []
    private var pending: Task<Void, Never>?
    private var answeredAt: ContinuousClock.Instant?
    private var rounds = 0
    private static let maxRounds = 10  // a server cannot keep the auth phase open forever

    func setHandler(_ h: @escaping @Sendable (Prompt) async -> [String]) {
        lock.lock(); handler = h; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let s = sem
        pending?.cancel()
        lock.unlock()
        s?.signal()
    }

    /// When the user last answered a prompt; time spent waiting on the user is not network time.
    func lastAnswered() -> ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return answeredAt
    }

    private func deliver(_ v: [String], generation g: Int) {
        lock.lock()
        guard g == generation, let s = sem else { lock.unlock(); return }
        answer = v
        lock.unlock()
        s.signal()
    }

    /// Returns answers, or empty when cancelled / timed out (which makes auth fail).
    func ask(_ prompt: Prompt, timeout: DispatchTimeInterval = .seconds(120)) -> [String] {
        lock.lock()
        rounds += 1
        guard let h = handler, !cancelled, rounds <= Self.maxRounds else { lock.unlock(); return [] }
        generation += 1
        let g = generation
        let s = DispatchSemaphore(value: 0)
        sem = s
        answer = []
        pending = Task.detached { [self] in deliver(await h(prompt), generation: g) }
        lock.unlock()

        let waited = s.wait(timeout: .now() + timeout)

        lock.lock()
        let result = cancelled ? [] : answer
        generation += 1   // invalidate any late delivery for this round
        sem = nil
        pending?.cancel()
        pending = nil
        answer = []
        if waited == .success && !cancelled { answeredAt = .now }  // only a real answer extends the deadline
        lock.unlock()
        return result
    }
}

/// The session's libssh2 `abstract`: reaches the keyboard-interactive bridge and counts every byte
/// libssh2 receives (including packets it handles internally, such as keepalive replies), which
/// `probe(timeout:)` uses as proof of life.
// @unchecked Sendable: `received` is guarded by `lock`; `kbd` is itself Sendable.
private final class CallbackContext: @unchecked Sendable {
    let kbd = KbdContext()
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    func add(_ n: Int) { lock.lock(); bytes &+= UInt64(n); lock.unlock() }
    var received: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// libssh2 RECV callback: plain `recv`, with libssh2's convention of returning `-errno`, plus a byte count.
private let recvCallback: @convention(c) (
    libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { socket, buffer, length, flags, abstract in
    let n = recv(socket, buffer, length, flags)
    if n < 0 {
        let e = errno
        return (e == EINTR || e == ENOENT) ? -Int(EAGAIN) : -Int(e)  // interrupted or no data yet: retry
    }
    if n > 0, let raw = abstract?.pointee {
        Unmanaged<CallbackContext>.fromOpaque(raw).takeUnretainedValue().add(n)
    }
    return n
}

private let kbdCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { name, nameLen, instr, instrLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0, let prompts, let responses, let raw = abstract?.pointee else { return }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(raw).takeUnretainedValue().kbd
    func str(_ p: UnsafePointer<CChar>?, _ n: Int32) -> String {
        guard let p, n > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: Int(n)), as: UTF8.self)
    }
    var items: [Prompt.Item] = []
    for i in 0..<Int(numPrompts) {
        let p = prompts[i]
        let text: String
        if let t = p.text { text = String(decoding: UnsafeBufferPointer(start: t, count: Int(p.length)), as: UTF8.self) } else { text = "" }
        items.append(.init(text: text, echo: p.echo != 0))
    }
    let prompt = Prompt(name: str(name, nameLen), instruction: str(instr, instrLen), items: items)
    let answers = ctx.ask(prompt)
    for i in 0..<Int(numPrompts) {
        let answer = i < answers.count ? answers[i] : ""
        let dup = strdup(answer)  // libssh2 frees this
        responses[i].text = dup
        responses[i].length = UInt32(answer.utf8.count)
    }
}

public actor SSHConnection: Session {
    public nonisolated let output: AsyncStream<Data>
    public nonisolated let state: AsyncStream<SessionState>
    private let outputCont: AsyncStream<Data>.Continuation
    private let stateCont: AsyncStream<SessionState>.Continuation

    private let host: String
    private let port: UInt16
    private let username: String
    private let auth: SSHAuth
    private var cols: Int
    private var rows: Int

    private var fd: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private nonisolated let callbacks = CallbackContext()
    private nonisolated var kbd: KbdContext { callbacks.kbd }
    private let executorQueue = DispatchSerialQueue(label: "SSHKit.SSHConnection")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }
    private var closed = false
    private var finished = false
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(host: String, port: UInt16 = 22, username: String, auth: SSHAuth, cols: Int = 80, rows: Int = 24) {
        self.host = host; self.port = port; self.username = username; self.auth = auth
        self.cols = cols; self.rows = rows
        (output, outputCont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        (state, stateCont) = AsyncStream.makeStream(of: SessionState.self, bufferingPolicy: .unbounded)
    }

    // MARK: Session

    public func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {
        do {
            try await withTaskCancellationHandler {
                try await doConnect(verifyHostKey: verifyHostKey)
            } onCancel: { kbd.cancel() }
        } catch {
            let e = (error as? SSHError) ?? (error is CancellationError ? .closed : .connectionFailed("\(error)"))
            await teardown(error: e)
            throw e
        }
    }

    /// No deadline: if a keepalive is partly queued on a full send buffer (a dying link), libssh2
    /// returns EAGAIN until it flushes; teardown or a failed probe ends the wait.
    public func write(_ data: Data) async throws {
        guard let channel, !closed else { throw SSHError.notConnected }
        var offset = 0
        while offset < data.count {
            let n = try await perform {
                data.withUnsafeBytes { buf in
                    libssh2_channel_write_ex(channel, 0, buf.baseAddress!.assumingMemoryBound(to: CChar.self) + offset, buf.count - offset)
                }
            }
            guard n >= 0 else { throw lastError() }
            offset += n
        }
    }

    public func resize(cols: Int, rows: Int) async throws {
        self.cols = cols; self.rows = rows
        guard let channel, !closed else { throw SSHError.notConnected }
        let rc = try await perform { Int(libssh2_channel_request_pty_size_ex(channel, Int32(cols), Int32(rows), 0, 0)) }
        guard rc == 0 else { throw lastError() }
    }

    public nonisolated func close() async {
        kbd.cancel()  // unblock a pending keyboard-interactive wait before queueing on the actor
        await teardown(error: nil)
    }

    // MARK: Connect flow

    private func doConnect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {
        stateCont.yield(.connecting)
        var deadline = ContinuousClock.now + .seconds(30)
        let newFd = try await SocketPoller.connect(host: host, port: port)
        if closed { Darwin.close(newFd); throw SSHError.closed }
        fd = newFd
        guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else { throw SSHError.connectionFailed("session init failed") }
        // The actor keeps `callbacks` alive for the session's whole life.
        libssh2_session_abstract(s).pointee = Unmanaged.passUnretained(callbacks).toOpaque()
        _ = libssh2_session_callback_set2(s, LIBSSH2_CALLBACK_RECV, unsafeBitCast(recvCallback, to: (@convention(c) () -> Void).self))
        session = s
        libssh2_session_set_blocking(s, 0)

        var rc = try await perform(deadline: deadline) { Int(libssh2_session_handshake(self.session!, self.fd)) }
        guard rc == 0 else { throw lastError() }

        let hostKey = try currentHostKey(s)
        stateCont.yield(.awaitingHostKeyDecision(hostKey))
        guard await verifyHostKey(hostKey) == .trust else { throw SSHError.hostKeyRejected }
        if closed { throw SSHError.closed }
        // The host-key prompt waits on the user; restart the network deadline after it.
        deadline = ContinuousClock.now + .seconds(30)

        stateCont.yield(.authenticating)
        try await authenticate(s, deadline: deadline)

        let ch = try await performPointer(deadline: deadline) {
            libssh2_channel_open_ex(s, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
        }
        channel = ch
        let term = "xterm-256color"
        rc = try await perform(deadline: deadline) {
            Int(libssh2_channel_request_pty_ex(self.channel!, term, UInt32(term.utf8.count), nil, 0, Int32(cols), Int32(rows), 0, 0))
        }
        guard rc == 0 else { throw lastError() }
        rc = try await perform(deadline: deadline) { Int(libssh2_channel_process_startup(self.channel!, "shell", 5, nil, 0)) }
        guard rc == 0 else { throw lastError() }

        stateCont.yield(.connected)
        Task { await self.readLoop() }
    }

    private func currentHostKey(_ s: OpaquePointer) throws -> HostKey {
        var len = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(s, &len, &type),
              let hash = libssh2_hostkey_hash(s, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw SSHError.protocolError(code: -1, message: "no host key")
        }
        let blob = Data(bytes: raw, count: len)
        let digest = Data(bytes: hash, count: 32)
        return HostKey(type: HostKeyType(libssh2: type), sha256: digest, keyData: blob)
    }

    private func authenticate(_ s: OpaquePointer, deadline: ContinuousClock.Instant) async throws {
        let user = username
        let ulen = UInt32(user.utf8.count)
        let rc: Int
        switch auth {
        case .password(let pw):
            rc = try await perform(deadline: deadline) {
                Int(libssh2_userauth_password_ex(s, user, ulen, pw, UInt32(pw.utf8.count), nil))
            }
        case .privateKey(let pem, let passphrase):
            guard !pem.isEmpty else { throw SSHError.authenticationFailed("Empty private key") }
            rc = try await perform(deadline: deadline) {
                pem.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress else { return Int(LIBSSH2_ERROR_AUTHENTICATION_FAILED) }
                    return Int(libssh2_userauth_publickey_frommemory(
                        s, user, user.utf8.count, nil, 0,
                        base.assumingMemoryBound(to: CChar.self), buf.count, passphrase))
                }
            }
        case .keyboardInteractive(let handler):
            kbd.setHandler(handler)
            rc = try await perform(deadline: deadline) {
                Int(libssh2_userauth_keyboard_interactive_ex(s, user, ulen, kbdCallback))
            }
        }
        if rc != 0 {
            if rc == Int(LIBSSH2_ERROR_AUTHENTICATION_FAILED) || rc == Int(LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
                throw SSHError.authenticationFailed("Authentication failed")
            }
            throw lastError()
        }
    }

    // MARK: Read loop

    private func readLoop() async {
        guard let channel else { return }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while !closed {
            await lock()
            if closed { unlock(); break }
            let n = buf.withUnsafeMutableBytes { libssh2_channel_read_ex(channel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
            var err = n < 0 ? lastError() : nil
            // A clean end (EOF, exit signal, non-zero exit status) is not a transport error.
            var cleanEnd = false  // a plain `if`, not `&&`: its autoclosure would send `channel` across isolation
            if n <= 0 && n != Int(LIBSSH2_ERROR_EAGAIN) { cleanEnd = Self.channelEndedCleanly(channel, session: session) }
            unlock()
            if cleanEnd { err = nil }
            if n > 0 {
                outputCont.yield(Data(buf[0..<n]))
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                _ = await Self.pollReadable(fd: fd, timeoutMs: 250)
            } else if n == 0 {
                await teardown(error: nil)
            } else {
                await teardown(error: err)
            }
        }
    }

    /// Call with the libssh2 lock held.
    private static func channelEndedCleanly(_ channel: OpaquePointer, session: OpaquePointer?) -> Bool {
        if libssh2_channel_eof(channel) == 1 { return true }
        var sig: UnsafeMutablePointer<CChar>?
        var sigLen = 0
        if libssh2_channel_get_exit_signal(channel, &sig, &sigLen, nil, nil, nil, nil) == 0, let sig {
            if let session { libssh2_free(session, sig) }  // libssh2 allocated the signal name
            return true
        }
        return libssh2_channel_get_exit_status(channel) != 0
    }

    /// Test hook: kills the socket under libssh2 without telling it, like a dropped network.
    internal func closeSocketForTesting() {
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }

    private static func pollReadable(fd: Int32, timeoutMs: Int32) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let rc = poll(&p, 1, timeoutMs)
                cont.resume(returning: rc > 0 && p.revents & Int16(POLLIN | POLLHUP) != 0)
            }
        }
    }

    /// Last time a keepalive went out, and last time a probe saw the peer answer.
    private var lastKeepaliveSent: ContinuousClock.Instant?
    private var lastProofOfLife: ContinuousClock.Instant?

    /// Sends a keepalive that wants a reply, then waits for any inbound bytes (the reply, or any other
    /// traffic). On timeout or a send failure the connection tears down as `.disconnected(.timeout)`
    /// and this returns false. Cancelling the calling task abandons the probe without touching the
    /// connection. A probe within 3 s of a successful one returns true without sending.
    public func probe(timeout: Duration) async -> Bool {
        guard session != nil, channel != nil, !closed else { return false }
        let now = ContinuousClock.now
        if let proof = lastProofOfLife, now - proof < .seconds(3) { return true }
        do {
            // libssh2 sends a keepalive only when `last_sent + interval <= time(NULL)` (whole seconds),
            // and returns 0 either way, so "did it send" cannot be read from its result. Waiting 3 s
            // after our previous send guarantees the next call sends.
            if let last = lastKeepaliveSent, ContinuousClock.now < last + .seconds(3) {
                try await Task.sleep(until: last + .seconds(3), clock: .continuous)
            }
            // The reply budget starts now, after any wait above.
            let deadline = ContinuousClock.now + timeout
            // Known limit: bytes already sitting in the kernel buffer from before a suspension can be
            // read after this baseline, so a half-open link can pass one probe; the next one catches it.
            let baseline = callbacks.received
            let rc = try await perform(deadline: deadline) {
                var next: Int32 = 0
                libssh2_keepalive_config(self.session!, 1, 2)
                return Int(libssh2_keepalive_send(self.session!, &next))
            }
            lastKeepaliveSent = ContinuousClock.now
            if rc != 0 { await teardown(error: .timeout); return false }
            while callbacks.received == baseline {
                if closed { return false }
                if ContinuousClock.now >= deadline {
                    await teardown(error: .timeout)
                    return false
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            lastProofOfLife = ContinuousClock.now
            return !closed
        } catch {
            if error is CancellationError || Task.isCancelled { return !closed }  // abandoned, not dead
            await teardown(error: .timeout)
            return false
        }
    }

    // MARK: Non-blocking driver

    private func lock() async {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
    }

    private func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    private func waitSocket(deadline: ContinuousClock.Instant?) async throws {
        guard let s = session else { throw SSHError.closed }
        let dirs = libssh2_session_block_directions(s)
        var interest: SocketPoller.Interest = []
        if dirs & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { interest.insert(.read) }
        if dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { interest.insert(.write) }
        if interest.isEmpty { interest = [.read, .write] }
        await SocketPoller.wait(fd: fd, interest: interest, timeoutMs: 250)
        try Task.checkCancellation()
        if closed { throw SSHError.closed }
        if let deadline {
            // Time the user spent answering a keyboard-interactive prompt does not count.
            var effective = deadline
            if let answered = kbd.lastAnswered(), answered + .seconds(30) > effective {
                effective = answered + .seconds(30)
            }
            if ContinuousClock.now > effective { throw SSHError.timeout }
        }
    }

    /// Runs `op` until it stops returning EAGAIN, waiting on socket readiness in between.
    private func perform(deadline: ContinuousClock.Instant? = nil, _ op: () -> Int) async throws -> Int {
        await lock()
        defer { unlock() }
        while true {
            if closed { throw SSHError.closed }
            let rc = op()
            if rc != Int(LIBSSH2_ERROR_EAGAIN) { return rc }
            try await waitSocket(deadline: deadline)
        }
    }

    private func performPointer(deadline: ContinuousClock.Instant? = nil, _ op: () -> OpaquePointer?) async throws -> OpaquePointer {
        await lock()
        defer { unlock() }
        while true {
            if closed { throw SSHError.closed }
            if let p = op() { return p }
            guard let s = session, libssh2_session_last_errno(s) == LIBSSH2_ERROR_EAGAIN else { throw lastError() }
            try await waitSocket(deadline: deadline)
        }
    }

    private func lastError() -> SSHError {
        guard let s = session else { return .notConnected }
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        let code = libssh2_session_last_error(s, &msg, &len, 0)
        let text = msg.map { String(cString: $0) } ?? "unknown error"
        return .protocolError(code: Int(code), message: text)
    }

    // MARK: Teardown

    private func teardown(error: SSHError?) async {
        guard !closed else { return }
        closed = true
        await lock()  // wait for any in-flight libssh2 call to leave the lock
        let bound = ContinuousClock.now + .seconds(2)
        if let channel {
            await drain(until: bound) { libssh2_channel_close(channel) }
            await drain(until: bound) { libssh2_channel_free(channel) }
            self.channel = nil
        }
        if let s = session {
            await drain(until: bound) { libssh2_session_disconnect_ex(s, SSH_DISCONNECT_BY_APPLICATION, "bye", "") }
            // Peer unresponsive: shut the socket down so the final free fails fast instead of EAGAIN.
            // shutdown, not close: the fd number must stay reserved while libssh2 can still write to it.
            if await drain(until: bound, { libssh2_session_free(s) }) == false {
                if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
                // Still EAGAIN on a shut-down socket is not expected; if it happens the session is
                // deliberately leaked (never touched again) rather than risking a use-after-free.
                _ = libssh2_session_free(s)
            }
            session = nil
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        unlock()
        if !finished {
            finished = true
            stateCont.yield(.disconnected(error))
            stateCont.finish()
            outputCont.finish()
        }
    }

    /// Repeats a non-blocking libssh2 close/free call through EAGAIN until `until`.
    /// Returns false if it was still EAGAIN at the deadline.
    @discardableResult
    private func drain(until deadline: ContinuousClock.Instant, _ op: () -> Int32) async -> Bool {
        while true {
            if op() != LIBSSH2_ERROR_EAGAIN { return true }
            if ContinuousClock.now >= deadline { return false }
            await SocketPoller.wait(fd: fd, interest: [.read, .write], timeoutMs: 50)
        }
    }
}
