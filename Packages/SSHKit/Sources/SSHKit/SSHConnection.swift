import Foundation
import Darwin
import CLibSSH2

/// Bridges the synchronous libssh2 keyboard-interactive callback to an async handler.
/// The actor runs on a dedicated dispatch queue (not the cooperative pool), and the wait is
/// bounded and can be cancelled from `close()` / task cancellation without entering the actor.
// @unchecked Sendable: all mutable state is guarded by `lock`; each round's semaphore is a lock-guarded snapshot, signalled outside the lock.
final class KbdContext: @unchecked Sendable {
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
    static let maxRounds = 10  // a server cannot keep the auth phase open forever

    func setHandler(_ h: @escaping @Sendable (Prompt) async -> [String]) {
        lock.lock()
        handler = h
        lock.unlock()
    }

    func clearHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        handler = nil
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
        let (ptr, len) = SSHConnection.copyUTF8ForLibSSH2(answer)  // libssh2 frees this
        responses[i].text = ptr
        responses[i].length = len
    }
}

/// Holds the Swift signing closure for the duration of one `libssh2_userauth_publickey` call.
private final class SignerBox: Sendable {
    let sign: @Sendable (Data) -> Data?
    init(_ sign: @escaping @Sendable (Data) -> Data?) { self.sign = sign }
}

private let signCallback: @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
    UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { _, sig, sigLen, data, dataLen, abstract in
    guard let sig, let sigLen, let raw = abstract?.pointee else { return -1 }
    let box = Unmanaged<SignerBox>.fromOpaque(raw).takeUnretainedValue()
    let input = data.map { Data(bytes: $0, count: dataLen) } ?? Data()
    guard let out = box.sign(input), !out.isEmpty,
          let mem = malloc(out.count)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
    out.copyBytes(to: mem, count: out.count)  // libssh2's default allocator frees this
    sig.pointee = mem
    sigLen.pointee = out.count
    return 0
}

private final class WeakConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var conn: SSHConnection?
    func set(_ c: SSHConnection) { lock.lock(); conn = c; lock.unlock() }
    func get() -> SSHConnection? { lock.lock(); defer { lock.unlock() }; return conn }
}

/// Non-blocking SSH session backed by libssh2 on a dedicated serial dispatch queue.
///
/// Each instance supports a single `connect(verifyHostKey:)` lifecycle. Callers must call `close()`
/// when done with a connection (including if `connect(verifyHostKey:)` was never called) so the
/// underlying socket, libssh2 handles, and async streams are released cleanly.
public actor SSHConnection: Session {
    private enum Lifecycle: Equatable {
        case idle
        case connecting
        case connected
        case closing
        case closed
    }

    private enum LockKind: Hashable, Sendable {
        case libssh2, write, resize, sftp
    }

    private final class LocalForwardState {
        let active: ActivePortForward
        let listenFd: Int32
        let acceptCancelFlag = SocketPoller.CancelFlag()
        var acceptTask: Task<Void, Never>?
        var clientTasks: [UUID: Task<Void, Never>] = [:]
        var clientWakeFlags: [UUID: SocketPoller.CancelFlag] = [:]

        init(active: ActivePortForward, listenFd: Int32) {
            self.active = active
            self.listenFd = listenFd
        }
    }

    private final class LockWaiter {
        let id = UUID()
        var continuation: CheckedContinuation<Void, Error>?
        var timeoutTask: Task<Void, Never>?
        var settled = false
    }

    private final class LockState {
        var locked = false
        var waiters: [LockWaiter] = []
    }

    public nonisolated let output: AsyncStream<Data>
    public nonisolated let state: AsyncStream<SessionState>
    private let stateCont: AsyncStream<SessionState>.Continuation

    private let host: String
    private let port: UInt16
    private let username: String
    private var auth: SSHAuth?
    private var cols: Int
    private var rows: Int

    private var fd: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var sftpSession: OpaquePointer?
    private nonisolated let callbacks = CallbackContext()
    private nonisolated var kbd: KbdContext { callbacks.kbd }
    private let executorQueue = DispatchSerialQueue(label: "SSHKit.SSHConnection")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }
    private var negotiated: NegotiatedAlgorithms?
    private var lifecycle: Lifecycle = .idle
    private var lockStates: [LockKind: LockState] = [.libssh2: .init(), .write: .init(), .resize: .init(), .sftp: .init()]

    private var readLoopTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var probeContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var activeSocketWaits: [UUID: SocketPoller.CancelFlag] = [:]
    private var socketWaitDrainContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeForwards: [UUID: LocalForwardState] = [:]
    private var stoppingForwardTasks: [UUID: Task<Void, Never>] = [:]

    // Bounded output buffer for backpressure (prevents unbounded growth on fast remote output).
    private var outputBuffer: [Data] = []
    private var outputHead = 0
    private var outputBufferedBytes = 0
    private var outputWaiter: CheckedContinuation<Data?, Never>?
    private var outputDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var outputFinished = false
    private static let outputHighWaterBytes = 2 * 1024 * 1024
    private static let outputLowWaterBytes = 1 * 1024 * 1024

    public init(host: String, port: UInt16 = 22, username: String, auth: SSHAuth, cols: Int = 80, rows: Int = 24) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.cols = Self.clampDimension(cols)
        self.rows = Self.clampDimension(rows)
        (state, stateCont) = AsyncStream.makeStream(of: SessionState.self, bufferingPolicy: .unbounded)
        let box = WeakConnectionBox()
        self.output = AsyncStream(unfolding: {
            await box.get()?.nextOutputChunk()
        }, onCancel: {
            Task { await box.get()?.cancelOutputStream() }
        })
        box.set(self)
    }

    // MARK: Helpers

    static func clampDimension(_ value: Int) -> Int {
        min(max(value, 1), 65535)
    }

    /// Allocates and copies raw UTF-8 bytes (preserving embedded NULs) for `libssh2` to `free()`.
    static func copyUTF8ForLibSSH2(_ answer: String) -> (UnsafeMutablePointer<CChar>?, UInt32) {
        let bytes = Array(answer.utf8)
        let count = min(bytes.count, Int(UInt32.max))
        guard let mem = malloc(max(1, count))?.assumingMemoryBound(to: CChar.self) else {
            return (nil, 0)
        }
        if count > 0 {
            bytes.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(mem, base, count)
                }
            }
        } else {
            mem.pointee = 0
        }
        return (mem, UInt32(count))
    }

    private var isClosingOrClosed: Bool {
        lifecycle == .closing || lifecycle == .closed
    }

    // MARK: Session

    /// Connects, verifies the host key, authenticates, and opens an interactive PTY shell.
    /// Rejects repeated or concurrent `connect()` calls. Callers must call `close()` when done.
    public func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {
        guard lifecycle == .idle else {
            throw isClosingOrClosed ? SSHError.closed : SSHError.connectionFailed("already connected or connecting")
        }
        lifecycle = .connecting
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
        guard lifecycle == .connected, channel != nil else { throw SSHError.notConnected }
        guard !data.isEmpty else { return }
        try await acquireLock(.write)
        defer { releaseLock(.write) }
        var offset = 0
        while offset < data.count {
            guard lifecycle == .connected else { throw SSHError.closed }
            let (n, opError) = try await perform {
                guard let ch = self.channel else { return Int(LIBSSH2_ERROR_BAD_USE) }
                return data.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress else { return 0 }
                    return libssh2_channel_write_ex(ch, 0, base.assumingMemoryBound(to: CChar.self) + offset, buf.count - offset)
                }
            }
            guard n > 0 else {
                let err = n == 0
                    ? SSHError.channelFailed("channel write returned 0")
                    : (opError ?? SSHError.channelFailed("channel write failed (\(n))"))
                await teardown(error: err)
                throw err
            }
            offset += n
            if offset < data.count {
                await Task.yield()
            }
        }
    }

    public func resize(cols: Int, rows: Int) async throws {
        let c = Self.clampDimension(cols)
        let r = Self.clampDimension(rows)
        self.cols = c
        self.rows = r
        guard lifecycle == .connected, channel != nil else { throw SSHError.notConnected }
        try await acquireLock(.resize)
        defer { releaseLock(.resize) }
        guard lifecycle == .connected else { throw SSHError.closed }
        let (rc, opError) = try await perform {
            guard let ch = self.channel else { return Int(LIBSSH2_ERROR_BAD_USE) }
            return Int(libssh2_channel_request_pty_size_ex(ch, Int32(c), Int32(r), 0, 0))
        }
        guard rc == 0 else {
            let err = opError ?? SSHError.channelFailed("resize failed (\(rc))")
            if rc != Int(LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED) {
                await teardown(error: err)
            }
            throw err
        }
    }

    public nonisolated func close() async {
        kbd.cancel()  // unblock a pending keyboard-interactive wait before queueing on the actor
        await teardown(error: nil)
    }

    /// The algorithms agreed in the handshake; nil before it completes.
    public func negotiatedAlgorithms() -> NegotiatedAlgorithms? { negotiated }

    // MARK: SFTP

    /// Resolves a remote path (including `""`, `"."`, and `"~"`) to its canonical path on the server.
    public func sftpResolvePath(_ path: String) async throws -> String {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()
        return try await resolvePathLocked(sftp: sftp, path: path)
    }

    /// Lists entries inside `path`, resolving `""`, `"."`, or `"~"` first, skipping `.` and `..`,
    /// and sorting directories first then case-insensitively by name.
    public func sftpListDirectory(path: String) async throws -> [SFTPEntry] {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()
        let resolvedPath = SFTPUtil.shouldResolveBeforeListing(path)
            ? try await resolvePathLocked(sftp: sftp, path: path)
            : path

        let handle = try await performSFTPPointer(sftp: sftp, context: resolvedPath) {
            resolvedPath.withCString { ptr in
                libssh2_sftp_open_ex(
                    sftp,
                    ptr,
                    UInt32(resolvedPath.utf8.count),
                    0,
                    0,
                    LIBSSH2_SFTP_OPENDIR
                )
            }
        }

        let nameCapacity = 4096
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: nameCapacity)
        let attrsPtr = UnsafeMutablePointer<LIBSSH2_SFTP_ATTRIBUTES>.allocate(capacity: 1)
        attrsPtr.initialize(to: LIBSSH2_SFTP_ATTRIBUTES())
        defer {
            nameBuf.deallocate()
            attrsPtr.deinitialize(count: 1)
            attrsPtr.deallocate()
        }

        do {
            var entries: [SFTPEntry] = []
            while true {
                try Task.checkCancellation()
                attrsPtr.pointee = LIBSSH2_SFTP_ATTRIBUTES()
                let rc = try await performSFTP(sftp: sftp, context: resolvedPath) {
                    Int(libssh2_sftp_readdir_ex(handle, nameBuf, nameCapacity, nil, 0, attrsPtr))
                }
                if rc == 0 { break }
                let rawBytes = UnsafeBufferPointer(
                    start: UnsafeRawPointer(nameBuf).assumingMemoryBound(to: UInt8.self),
                    count: min(rc, nameCapacity)
                )
                let len = rawBytes.firstIndex(of: 0) ?? rawBytes.count
                let name = String(decoding: rawBytes.prefix(len), as: UTF8.self)
                if name.isEmpty || name == "." || name == ".." {
                    continue
                }
                entries.append(SFTPUtil.makeEntry(directory: resolvedPath, name: name, attrs: attrsPtr.pointee))
            }
            await closeSFTPHandle(handle)
            return SFTPPath.sortEntries(entries)
        } catch {
            await closeSFTPHandle(handle)
            throw error
        }
    }

    /// Downloads a remote file in 32 KB chunks up to `maxBytes`.
    public func sftpDownloadFile(remotePath: String, maxBytes: Int = 50 * 1024 * 1024) async throws -> Data {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        guard maxBytes >= 0 else { throw SFTPError.fileTooLarge(0) }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()

        let handle = try await performSFTPPointer(sftp: sftp, context: remotePath) {
            remotePath.withCString { ptr in
                libssh2_sftp_open_ex(
                    sftp,
                    ptr,
                    UInt32(remotePath.utf8.count),
                    UInt(LIBSSH2_FXF_READ),
                    0,
                    LIBSSH2_SFTP_OPENFILE
                )
            }
        }

        let chunkCapacity = 32 * 1024
        let chunkBuf = UnsafeMutablePointer<CChar>.allocate(capacity: chunkCapacity)
        defer { chunkBuf.deallocate() }

        do {
            var data = Data()
            while true {
                try Task.checkCancellation()
                let n = try await performSFTP(sftp: sftp, context: remotePath) {
                    libssh2_sftp_read(handle, chunkBuf, chunkCapacity)
                }
                if n == 0 { break }
                if data.count + n > maxBytes {
                    throw SFTPError.fileTooLarge(data.count + n)
                }
                data.append(UnsafeRawBufferPointer(start: chunkBuf, count: n).bindMemory(to: UInt8.self))
            }
            await closeSFTPHandle(handle)
            return data
        } catch {
            await closeSFTPHandle(handle)
            throw error
        }
    }

    /// Uploads `data` to `remotePath` (creating or truncating the remote file).
    public func sftpUploadFile(data: Data, remotePath: String, permissions: Int = 0o644) async throws {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()

        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let handle = try await performSFTPPointer(sftp: sftp, context: remotePath) {
            remotePath.withCString { ptr in
                libssh2_sftp_open_ex(
                    sftp,
                    ptr,
                    UInt32(remotePath.utf8.count),
                    flags,
                    permissions,
                    LIBSSH2_SFTP_OPENFILE
                )
            }
        }

        do {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let chunkLen = min(32 * 1024, data.count - offset)
                let written = try await performSFTP(sftp: sftp, context: remotePath) {
                    data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return 0 }
                        return libssh2_sftp_write(
                            handle,
                            base.assumingMemoryBound(to: CChar.self) + offset,
                            chunkLen
                        )
                    }
                }
                guard written > 0 else {
                    throw SFTPError.ioFailed("Failed writing \(remotePath): short write (0 bytes)")
                }
                offset += written
            }
            await closeSFTPHandle(handle)
        } catch {
            await closeSFTPHandle(handle)
            throw error
        }
    }

    /// Creates a remote directory at `path`.
    public func sftpMakeDirectory(path: String, permissions: Int = 0o755) async throws {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()
        _ = try await performSFTP(sftp: sftp, context: path) {
            path.withCString { ptr in
                Int(libssh2_sftp_mkdir_ex(sftp, ptr, UInt32(path.utf8.count), permissions))
            }
        }
    }

    /// Deletes a remote file or empty directory.
    public func sftpDelete(path: String, isDirectory: Bool) async throws {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()
        _ = try await performSFTP(sftp: sftp, context: path) {
            path.withCString { ptr in
                let len = UInt32(path.utf8.count)
                if isDirectory {
                    return Int(libssh2_sftp_rmdir_ex(sftp, ptr, len))
                } else {
                    return Int(libssh2_sftp_unlink_ex(sftp, ptr, len))
                }
            }
        }
    }

    /// Renames or moves a remote file or directory.
    public func sftpRename(from sourcePath: String, to destinationPath: String) async throws {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        try await acquireLock(.sftp)
        defer { releaseLock(.sftp) }
        let sftp = try await ensureSFTP()
        let renameFlags = Int(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
        _ = try await performSFTP(sftp: sftp, context: sourcePath) {
            sourcePath.withCString { srcPtr in
                destinationPath.withCString { dstPtr in
                    Int(libssh2_sftp_rename_ex(
                        sftp,
                        srcPtr,
                        UInt32(sourcePath.utf8.count),
                        dstPtr,
                        UInt32(destinationPath.utf8.count),
                        renameFlags
                    ))
                }
            }
        }
    }

    private func ensureSFTP() async throws -> OpaquePointer {
        guard lifecycle == .connected, session != nil else { throw SFTPError.notConnected }
        if let sftp = sftpSession {
            return sftp
        }
        do {
            let sftp = try await performPointer {
                guard self.lifecycle == .connected, let s = self.session else { return nil }
                return libssh2_sftp_init(s)
            }
            sftpSession = sftp
            return sftp
        } catch let error as SFTPError {
            throw error
        } catch let error as SSHError {
            switch error {
            case .notConnected, .closed:
                throw SFTPError.notConnected
            case .protocolError(_, let message):
                throw SFTPError.initFailed(message)
            default:
                throw SFTPError.initFailed("\(error)")
            }
        }
    }

    private func resolvePathLocked(sftp: OpaquePointer, path: String) async throws -> String {
        let normalized = SFTPUtil.realpathInput(for: path)
        let capacity = 4096
        let targetBuf = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { targetBuf.deallocate() }

        let rc = try await performSFTP(sftp: sftp, context: path) {
            normalized.withCString { ptr in
                Int(libssh2_sftp_symlink_ex(
                    sftp,
                    ptr,
                    UInt32(normalized.utf8.count),
                    targetBuf,
                    UInt32(capacity),
                    LIBSSH2_SFTP_REALPATH
                ))
            }
        }
        guard rc > 0 else { return "/" }
        let rawBytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(targetBuf).assumingMemoryBound(to: UInt8.self),
            count: min(rc, capacity)
        )
        let len = rawBytes.firstIndex(of: 0) ?? rawBytes.count
        let resolved = String(decoding: rawBytes.prefix(len), as: UTF8.self)
        return resolved.isEmpty ? "/" : resolved
    }

    private func performSFTP(
        sftp: OpaquePointer,
        context: String,
        _ op: () -> Int
    ) async throws -> Int {
        while true {
            try Task.checkCancellation()
            try await acquireLock(.libssh2)
            let rc: Int
            let interest: SocketPoller.Interest
            do {
                guard lifecycle == .connected, session != nil, sftpSession == sftp else {
                    releaseLock(.libssh2)
                    throw SFTPError.notConnected
                }
                rc = op()
                if rc != Int(LIBSSH2_ERROR_EAGAIN) {
                    if rc < 0 {
                        let err = captureSFTPError(sftp: sftp, context: context)
                        releaseLock(.libssh2)
                        throw err
                    }
                    releaseLock(.libssh2)
                    return rc
                }
                interest = blockInterest()
            }
            releaseLock(.libssh2)
            try await waitSFTPSocket(interest: interest, context: context)
        }
    }

    private func performSFTPPointer(
        sftp: OpaquePointer,
        context: String,
        _ op: () -> OpaquePointer?
    ) async throws -> OpaquePointer {
        while true {
            try Task.checkCancellation()
            try await acquireLock(.libssh2)
            let interest: SocketPoller.Interest
            do {
                guard lifecycle == .connected, let s = session, sftpSession == sftp else {
                    releaseLock(.libssh2)
                    throw SFTPError.notConnected
                }
                if let handle = op() {
                    releaseLock(.libssh2)
                    return handle
                }
                if libssh2_session_last_errno(s) != LIBSSH2_ERROR_EAGAIN {
                    let err = captureSFTPError(sftp: sftp, context: context)
                    releaseLock(.libssh2)
                    throw err
                }
                interest = blockInterest()
            }
            releaseLock(.libssh2)
            try await waitSFTPSocket(interest: interest, context: context)
        }
    }

    private func waitSFTPSocket(interest: SocketPoller.Interest, context: String) async throws {
        do {
            try await waitSocket(interest: interest, deadline: nil)
        } catch let error as SSHError {
            if error == .closed || error == .notConnected {
                throw SFTPError.notConnected
            }
            throw SFTPError.ioFailed("\(context): \(error)")
        }
    }

    /// Call only while `.libssh2` lock is held.
    private func captureSFTPError(sftp: OpaquePointer, context: String) -> SFTPError {
        guard let s = session else { return .notConnected }
        let sshCode = libssh2_session_last_errno(s)
        if sshCode == LIBSSH2_ERROR_SFTP_PROTOCOL {
            return SFTPUtil.mapStatus(libssh2_sftp_last_error(sftp), context: context)
        }
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        _ = libssh2_session_last_error(s, &msg, &len, 0)
        let text = msg.map { String(cString: $0) } ?? "error \(sshCode)"
        return .ioFailed("\(context): \(text)")
    }

    private func closeSFTPHandle(_ handle: OpaquePointer) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            try? await acquireLock(.libssh2, cancellable: false)
            guard lifecycle == .connected, sftpSession != nil else {
                if lifecycle == .closing, sftpSession != nil {
                    _ = libssh2_sftp_close_handle(handle)
                }
                releaseLock(.libssh2)
                return
            }
            let rc = libssh2_sftp_close_handle(handle)
            if rc != LIBSSH2_ERROR_EAGAIN {
                releaseLock(.libssh2)
                return
            }
            if ContinuousClock.now >= deadline || fd < 0 {
                releaseLock(.libssh2)
                return
            }
            let interest = blockInterest()
            releaseLock(.libssh2)
            await waitOnSocket(interest: interest, timeoutMs: 50)
        }
    }

    // MARK: Local port forwarding (-L)

    /// Starts a local TCP listener on `127.0.0.1` and forwards connections over SSH `direct-tcpip`.
    public func startLocalForward(_ rule: PortForwardRule) async throws -> ActivePortForward {
        guard lifecycle == .connected, session != nil else { throw SSHError.notConnected }
        let trimmedHost = rule.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, rule.remotePort > 0 else {
            throw SSHError.channelFailed("invalid port forward rule")
        }
        guard activeForwards[rule.id] == nil, stoppingForwardTasks[rule.id] == nil else {
            throw SSHError.channelFailed("port forward already active")
        }

        let (listenFd, boundPort) = try LocalForwardSocket.bindAndListen(port: rule.localPort)
        let normalizedRule = PortForwardRule(
            id: rule.id,
            name: rule.name,
            localPort: rule.localPort,
            remoteHost: trimmedHost,
            remotePort: rule.remotePort
        )
        let active = ActivePortForward(rule: normalizedRule, boundLocalPort: boundPort)
        let state = LocalForwardState(active: active, listenFd: listenFd)
        activeForwards[rule.id] = state
        let forwardID = rule.id
        state.acceptTask = Task { [weak self] in
            await self?.runForwardAcceptLoop(forwardID: forwardID)
        }
        return active
    }

    /// Stops an active local port forward, closing its listener and active client tunnels.
    public func stopLocalForward(id: UUID) async {
        if let existingStop = stoppingForwardTasks[id] {
            await existingStop.value
            return
        }
        guard let state = activeForwards.removeValue(forKey: id) else { return }
        let stopTask = Task { await self.teardownForwardState(state) }
        stoppingForwardTasks[id] = stopTask
        await stopTask.value
        stoppingForwardTasks.removeValue(forKey: id)
    }

    /// Returns all currently active local port forwards on this connection.
    public func activePortForwards() -> [ActivePortForward] {
        activeForwards.values.map(\.active)
    }

    private func teardownForwardState(_ state: LocalForwardState) async {
        state.acceptCancelFlag.cancel()
        state.acceptTask?.cancel()
        for flag in state.clientWakeFlags.values {
            flag.cancel()
        }
        let clients = Array(state.clientTasks.values)
        state.clientTasks.removeAll()
        for t in clients {
            t.cancel()
        }
        await state.acceptTask?.value
        state.acceptTask = nil
        Darwin.close(state.listenFd)
        for t in clients {
            await t.value
        }
    }

    private func stopAllForwardsForTeardown() async {
        let forwards = Array(activeForwards.values)
        activeForwards.removeAll()
        for state in forwards {
            await teardownForwardState(state)
        }
        let inFlightStops = Array(stoppingForwardTasks.values)
        for task in inFlightStops {
            await task.value
        }
    }

    private func runForwardAcceptLoop(forwardID: UUID) async {
        while !Task.isCancelled && lifecycle == .connected {
            guard let state = activeForwards[forwardID] else { break }
            let listenFd = state.listenFd
            let cancelFlag = state.acceptCancelFlag
            let boundPort = state.active.boundLocalPort
            let rule = state.active.rule
            await SocketPoller.wait(fd: listenFd, interest: .read, timeoutMs: 250, cancelFlag: cancelFlag)
            if Task.isCancelled || cancelFlag.isCancelled || lifecycle != .connected || activeForwards[forwardID] == nil {
                break
            }

            while !Task.isCancelled && !cancelFlag.isCancelled && lifecycle == .connected {
                guard let currentState = activeForwards[forwardID] else { return }
                switch LocalForwardSocket.acceptNonBlocking(listenFd: listenFd, fallbackPort: boundPort) {
                case .wouldBlock:
                    break
                case .error:
                    return
                case .accepted(let clientFd, let sourcePort):
                    let clientID = UUID()
                    let task = Task { [weak self] in
                        guard let self else {
                            Darwin.close(clientFd)
                            return
                        }
                        await self.handleForwardedClient(
                            forwardID: forwardID,
                            clientID: clientID,
                            clientFd: clientFd,
                            remoteHost: rule.remoteHost,
                            remotePort: rule.remotePort,
                            sourceHost: "127.0.0.1",
                            sourcePort: sourcePort
                        )
                    }
                    currentState.clientTasks[clientID] = task
                    continue
                }
                break
            }
        }
    }

    private struct ForwardPumpState {
        var toSSH = ForwardPipeBuffer()
        var toClient = ForwardPipeBuffer()
        var clientEOF = false
        var sentChannelEOF = false
        var channelEOF = false
        var shutClientWrite = false
    }

    private struct ForwardChannelStepResult {
        var didProgress = false
        var sshInterest: SocketPoller.Interest = []
        var sshError = false
    }

    private func handleForwardedClient(
        forwardID: UUID,
        clientID: UUID,
        clientFd: Int32,
        remoteHost: String,
        remotePort: UInt16,
        sourceHost: String,
        sourcePort: UInt16
    ) async {
        defer { Darwin.close(clientFd) }

        let fwdChannel: OpaquePointer
        do {
            fwdChannel = try await openDirectTCPIPChannel(
                remoteHost: remoteHost,
                remotePort: remotePort,
                sourceHost: sourceHost,
                sourcePort: sourcePort
            )
        } catch {
            removeForwardClient(forwardID: forwardID, clientID: clientID)
            return
        }

        var localReadBuf = [UInt8](repeating: 0, count: 32 * 1024)
        var sshReadBuf = [UInt8](repeating: 0, count: 32 * 1024)
        var pump = ForwardPumpState()

        while !Task.isCancelled && lifecycle == .connected && activeForwards[forwardID] != nil {
            var didProgress = false

            if !pump.clientEOF && pump.toSSH.availableCount < 64 * 1024 {
                let n = localReadBuf.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.recv(clientFd, base, raw.count, 0)
                }
                if n > 0 {
                    pump.toSSH.append(localReadBuf[0..<n])
                    didProgress = true
                } else if n == 0 {
                    pump.clientEOF = true
                    didProgress = true
                } else if !Self.isTransientSocketError(errno) {
                    break
                }
            }

            let step = await stepForwardedChannelIO(
                forwardID: forwardID,
                clientID: clientID,
                channel: fwdChannel,
                pump: &pump,
                sshReadBuf: &sshReadBuf
            )
            if step.sshError { break }
            if step.didProgress { didProgress = true }

            if !pump.toClient.isEmpty {
                let sent = pump.toClient.withReadableBytes { ptr, count in
                    Darwin.send(clientFd, ptr, count, 0)
                }
                if sent > 0 {
                    pump.toClient.consume(sent)
                    didProgress = true
                } else if sent == 0 || !Self.isTransientSocketError(errno) {
                    break
                }
            }

            if pump.channelEOF && pump.toClient.isEmpty && !pump.shutClientWrite {
                _ = Darwin.shutdown(clientFd, SHUT_WR)
                pump.shutClientWrite = true
                didProgress = true
            }

            if pump.clientEOF && pump.sentChannelEOF && pump.channelEOF && pump.toClient.isEmpty {
                break
            }

            if didProgress {
                await Task.yield()
                continue
            }

            await waitForForwardActivity(
                forwardID: forwardID,
                clientID: clientID,
                clientFd: clientFd,
                pump: pump,
                sshInterest: step.sshInterest
            )
        }

        await closeForwardedChannel(fwdChannel)
        removeForwardClient(forwardID: forwardID, clientID: clientID)
    }

    private func openDirectTCPIPChannel(
        remoteHost: String,
        remotePort: UInt16,
        sourceHost: String,
        sourcePort: UInt16
    ) async throws -> OpaquePointer {
        try await performPointer(deadline: ContinuousClock.now + .seconds(15)) {
            guard self.lifecycle == .connected, let s = self.session else { return nil }
            return remoteHost.withCString { rHost in
                sourceHost.withCString { sHost in
                    libssh2_channel_direct_tcpip_ex(s, rHost, Int32(remotePort), sHost, Int32(sourcePort))
                }
            }
        }
    }

    private func stepForwardedChannelIO(
        forwardID: UUID,
        clientID: UUID,
        channel fwdChannel: OpaquePointer,
        pump: inout ForwardPumpState,
        sshReadBuf: inout [UInt8]
    ) async -> ForwardChannelStepResult {
        var result = ForwardChannelStepResult()
        let receivedBefore = callbacks.received
        do {
            try await acquireLock(.libssh2)
        } catch {
            result.sshError = true
            return result
        }
        guard lifecycle == .connected, session != nil, activeForwards[forwardID] != nil else {
            releaseLock(.libssh2)
            result.sshError = true
            return result
        }

        if !pump.toSSH.isEmpty {
            let w = pump.toSSH.withReadableBytes { ptr, count in
                ptr.withMemoryRebound(to: CChar.self, capacity: count) { cPtr in
                    libssh2_channel_write_ex(fwdChannel, 0, cPtr, count)
                }
            }
            if w > 0 {
                pump.toSSH.consume(w)
                result.didProgress = true
            } else if w == Int(LIBSSH2_ERROR_EAGAIN) {
                result.sshInterest.formUnion(blockInterest())
            } else {
                result.sshError = true
            }
        }

        if !result.sshError && pump.clientEOF && pump.toSSH.isEmpty && !pump.sentChannelEOF {
            let rc = libssh2_channel_send_eof(fwdChannel)
            if rc == 0 {
                pump.sentChannelEOF = true
                result.didProgress = true
            } else if rc == LIBSSH2_ERROR_EAGAIN {
                result.sshInterest.formUnion(blockInterest())
            } else {
                result.sshError = true
            }
        }

        if !result.sshError && !pump.channelEOF && pump.toClient.availableCount < 64 * 1024 {
            let r = sshReadBuf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return libssh2_channel_read_ex(
                    fwdChannel,
                    0,
                    base.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }
            if r > 0 {
                pump.toClient.append(sshReadBuf[0..<r])
                result.didProgress = true
            } else if r == 0 || r == Int(LIBSSH2_ERROR_EAGAIN) {
                if libssh2_channel_eof(fwdChannel) == 1 {
                    pump.channelEOF = true
                    result.didProgress = true
                } else if r == Int(LIBSSH2_ERROR_EAGAIN) {
                    result.sshInterest.formUnion(blockInterest())
                } else {
                    result.sshInterest.insert(.read)
                }
            } else {
                result.sshError = true
            }
        }

        let receivedAfter = callbacks.received
        releaseLock(.libssh2)

        if receivedAfter != receivedBefore {
            wakeForwardClients(excluding: clientID)
        }
        return result
    }

    private func waitForForwardActivity(
        forwardID: UUID,
        clientID: UUID,
        clientFd: Int32,
        pump: ForwardPumpState,
        sshInterest: SocketPoller.Interest
    ) async {
        var targets: [(fd: Int32, interest: SocketPoller.Interest)] = []
        var clientInterest: SocketPoller.Interest = []
        if !pump.clientEOF && pump.toSSH.availableCount < 64 * 1024 {
            clientInterest.insert(.read)
        }
        if !pump.toClient.isEmpty {
            clientInterest.insert(.write)
        }
        if !clientInterest.isEmpty {
            targets.append((fd: clientFd, interest: clientInterest))
        }

        let wakeFlag = SocketPoller.CancelFlag()
        var sshWaitID: UUID?
        if fd >= 0 && !sshInterest.isEmpty {
            targets.append((fd: fd, interest: sshInterest))
            sshWaitID = registerSocketWait(wakeFlag)
        }

        if targets.isEmpty {
            if let wid = sshWaitID { unregisterSocketWait(wid) }
            try? await Task.sleep(for: .milliseconds(10))
            return
        }

        activeForwards[forwardID]?.clientWakeFlags[clientID] = wakeFlag
        await SocketPoller.waitAny(targets, timeoutMs: 250, cancelFlag: wakeFlag, sliceMs: 20)
        activeForwards[forwardID]?.clientWakeFlags.removeValue(forKey: clientID)
        if let wid = sshWaitID {
            unregisterSocketWait(wid)
        }
    }

    private static func isTransientSocketError(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }

    private func closeForwardedChannel(_ ch: OpaquePointer) async {
        let deadline = ContinuousClock.now + .seconds(1)
        var closed = false
        while true {
            try? await acquireLock(.libssh2, cancellable: false)
            guard session != nil, lifecycle == .connected || lifecycle == .closing else {
                releaseLock(.libssh2)
                return
            }
            if !closed {
                let crc = libssh2_channel_close(ch)
                if crc == LIBSSH2_ERROR_EAGAIN {
                    if ContinuousClock.now >= deadline || fd < 0 {
                        releaseLock(.libssh2)
                        return
                    }
                    let interest = blockInterest()
                    releaseLock(.libssh2)
                    await waitForChannelDrainSocket(interest: interest)
                    continue
                }
                closed = true
            }
            let frc = libssh2_channel_free(ch)
            if frc != LIBSSH2_ERROR_EAGAIN || ContinuousClock.now >= deadline || fd < 0 {
                releaseLock(.libssh2)
                return
            }
            let interest = blockInterest()
            releaseLock(.libssh2)
            await waitForChannelDrainSocket(interest: interest)
        }
    }

    private func waitForChannelDrainSocket(interest: SocketPoller.Interest) async {
        guard fd >= 0, lifecycle == .connected || lifecycle == .closing else { return }
        let currentFd = fd
        let flag = SocketPoller.CancelFlag()
        let id = registerSocketWait(flag)
        await SocketPoller.wait(fd: currentFd, interest: interest, timeoutMs: 50, cancelFlag: flag)
        unregisterSocketWait(id)
    }

    private func removeForwardClient(forwardID: UUID, clientID: UUID) {
        activeForwards[forwardID]?.clientWakeFlags.removeValue(forKey: clientID)
        activeForwards[forwardID]?.clientTasks.removeValue(forKey: clientID)
    }

    private func wakeForwardClients(excluding excludedClientID: UUID? = nil) {
        for state in activeForwards.values {
            for (cid, flag) in state.clientWakeFlags where cid != excludedClientID {
                flag.cancel()
            }
        }
    }

    // MARK: Connect flow

    private func doConnect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {
        try Task.checkCancellation()
        stateCont.yield(.connecting)
        var deadline = ContinuousClock.now + .seconds(30)
        let newFd = try await SocketPoller.connect(host: host, port: port)
        if Task.isCancelled {
            Darwin.close(newFd)
            throw CancellationError()
        }
        guard lifecycle == .connecting else {
            Darwin.close(newFd)
            throw SSHError.closed
        }
        fd = newFd

        guard LibSSH2Runtime.ensureInitialized() else {
            throw SSHError.connectionFailed("libssh2_init failed")
        }
        guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.connectionFailed("session init failed")
        }
        // The actor keeps `callbacks` alive for the session's whole life.
        libssh2_session_abstract(s).pointee = Unmanaged.passUnretained(callbacks).toOpaque()
        _ = libssh2_session_callback_set2(s, LIBSSH2_CALLBACK_RECV, unsafeBitCast(recvCallback, to: (@convention(c) () -> Void).self))
        session = s
        libssh2_session_set_blocking(s, 0)

        // Fail closed: method_pref silently drops names libssh2 lacks, so check them all first.
        let missing = AlgorithmPolicy.unsupportedNames(session: s)
        guard missing.isEmpty else {
            throw SSHError.connectionFailed("algorithm policy not supported: \(missing.joined(separator: ", "))")
        }
        for (method, name, list) in AlgorithmPolicy.methodLists where libssh2_session_method_pref(s, method, list) != 0 {
            throw SSHError.connectionFailed("algorithm policy rejected: \(name)")
        }

        var (rc, opErr) = try await perform(deadline: deadline) {
            guard let s = self.session else { return Int(LIBSSH2_ERROR_BAD_USE) }
            return Int(libssh2_session_handshake(s, self.fd))
        }
        guard rc == 0 else { throw opErr ?? SSHError.connectionFailed("handshake failed (\(rc))") }

        let hostKey = try currentHostKey(s)
        stateCont.yield(.awaitingHostKeyDecision(hostKey))
        guard await verifyHostKey(hostKey) == .trust else { throw SSHError.hostKeyRejected }
        try Task.checkCancellation()
        guard lifecycle == .connecting else { throw SSHError.closed }

        func method(_ m: Int32) -> String { libssh2_session_methods(s, m).map { String(cString: $0) } ?? "" }
        negotiated = NegotiatedAlgorithms(
            kex: method(LIBSSH2_METHOD_KEX), hostKey: method(LIBSSH2_METHOD_HOSTKEY),
            cipher: method(LIBSSH2_METHOD_CRYPT_CS), mac: method(LIBSSH2_METHOD_MAC_CS))
        // The host-key prompt waits on the user; restart the network deadline after it.
        deadline = ContinuousClock.now + .seconds(30)

        stateCont.yield(.authenticating)
        try await authenticate(s, deadline: deadline)

        let ch = try await performPointer(deadline: deadline) {
            guard let s = self.session else { return nil }
            return libssh2_channel_open_ex(s, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
        }
        channel = ch
        let term = "xterm-256color"
        let ptyCols = Int32(cols)
        let ptyRows = Int32(rows)
        (rc, opErr) = try await perform(deadline: deadline) {
            guard let ch = self.channel else { return Int(LIBSSH2_ERROR_BAD_USE) }
            return Int(libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, ptyCols, ptyRows, 0, 0))
        }
        guard rc == 0 else { throw opErr ?? SSHError.channelFailed("pty request failed (\(rc))") }
        (rc, opErr) = try await perform(deadline: deadline) {
            guard let ch = self.channel else { return Int(LIBSSH2_ERROR_BAD_USE) }
            return Int(libssh2_channel_process_startup(ch, "shell", 5, nil, 0))
        }
        guard rc == 0 else { throw opErr ?? SSHError.channelFailed("shell startup failed (\(rc))") }

        guard lifecycle == .connecting else { throw SSHError.closed }
        lifecycle = .connected
        stateCont.yield(.connected)
        readLoopTask = Task { await self.readLoop() }
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
        defer {
            auth = nil
            kbd.clearHandler()
        }
        guard let currentAuth = auth else {
            throw SSHError.authenticationFailed("Missing credentials")
        }
        let user = username
        let ulen = UInt32(user.utf8.count)
        let rc: Int
        let opErr: SSHError?
        switch currentAuth {
        case .password(let pw):
            (rc, opErr) = try await perform(deadline: deadline) {
                Int(libssh2_userauth_password_ex(s, user, ulen, pw, UInt32(pw.utf8.count), nil))
            }
        case .privateKey(let pem, let passphrase):
            guard !pem.isEmpty else { throw SSHError.authenticationFailed("Empty private key") }
            (rc, opErr) = try await perform(deadline: deadline) {
                pem.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress else { return Int(LIBSSH2_ERROR_AUTHENTICATION_FAILED) }
                    return Int(libssh2_userauth_publickey_frommemory(
                        s, user, user.utf8.count, nil, 0,
                        base.assumingMemoryBound(to: CChar.self), buf.count, passphrase))
                }
            }
        case .signer(let blob, let sign):
            guard !blob.isEmpty else { throw SSHError.authenticationFailed("Empty public key") }
            // The box and the abstract slot must outlive every EAGAIN retry; libssh2 keeps the slot's address.
            let box = Unmanaged.passRetained(SignerBox(sign))
            let slot = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
            slot.initialize(to: box.toOpaque())
            defer { slot.deallocate(); box.release() }
            (rc, opErr) = try await perform(deadline: deadline) {
                blob.withUnsafeBytes { buf in
                    guard let base = buf.baseAddress else { return Int(LIBSSH2_ERROR_AUTHENTICATION_FAILED) }
                    return Int(libssh2_userauth_publickey(
                        s, user, base.assumingMemoryBound(to: UInt8.self), buf.count,
                        signCallback, slot))
                }
            }
        case .keyboardInteractive(let handler):
            kbd.setHandler(handler)
            (rc, opErr) = try await perform(deadline: deadline) {
                Int(libssh2_userauth_keyboard_interactive_ex(s, user, ulen, kbdCallback))
            }
        }
        if rc != 0 {
            if rc == Int(LIBSSH2_ERROR_AUTHENTICATION_FAILED) || rc == Int(LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
                throw SSHError.authenticationFailed("Authentication failed")
            }
            throw opErr ?? SSHError.authenticationFailed("Authentication failed (\(rc))")
        }
    }

    // MARK: Bounded output stream

    private func enqueueOutput(_ data: Data) {
        guard !outputFinished else { return }
        if let waiter = outputWaiter {
            outputWaiter = nil
            waiter.resume(returning: data)
            return
        }
        outputBuffer.append(data)
        outputBufferedBytes += data.count
    }

    private func nextOutputChunk() async -> Data? {
        if let chunk = dequeueOutput() {
            return chunk
        }
        if outputFinished || Task.isCancelled {
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                if let chunk = dequeueOutput() {
                    cont.resume(returning: chunk)
                    return
                }
                if outputFinished || Task.isCancelled {
                    cont.resume(returning: nil)
                    return
                }
                outputWaiter?.resume(returning: nil)
                outputWaiter = cont
            }
        } onCancel: {
            Task { await self.cancelOutputWaiter() }
        }
    }

    private func dequeueOutput() -> Data? {
        guard outputHead < outputBuffer.count else { return nil }
        let chunk = outputBuffer[outputHead]
        outputBuffer[outputHead] = Data()
        outputHead += 1
        if outputHead >= 64 && outputHead * 2 >= outputBuffer.count {
            outputBuffer.removeFirst(outputHead)
            outputHead = 0
        }
        outputBufferedBytes -= chunk.count
        if outputBufferedBytes <= Self.outputLowWaterBytes {
            resumeOutputDrainWaiters()
        }
        return chunk
    }

    private func cancelOutputWaiter() {
        guard let waiter = outputWaiter else { return }
        outputWaiter = nil
        waiter.resume(returning: nil)
    }

    private func cancelOutputStream() {
        outputFinished = true
        outputBuffer.removeAll()
        outputHead = 0
        outputBufferedBytes = 0
        cancelOutputWaiter()
        resumeOutputDrainWaiters()
    }

    private func finishOutput() {
        outputFinished = true
        cancelOutputWaiter()
        resumeOutputDrainWaiters()
    }

    private func waitForOutputDrain() async {
        while outputBufferedBytes > Self.outputLowWaterBytes && !outputFinished && lifecycle == .connected && !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if outputBufferedBytes <= Self.outputLowWaterBytes || outputFinished || lifecycle != .connected || Task.isCancelled {
                        cont.resume()
                        return
                    }
                    outputDrainWaiters.append(cont)
                }
            } onCancel: {
                Task { await self.resumeOutputDrainWaiters() }
            }
        }
    }

    private func resumeOutputDrainWaiters() {
        guard !outputDrainWaiters.isEmpty else { return }
        let waiters = outputDrainWaiters
        outputDrainWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    // MARK: Read loop

    private func readLoop() async {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while !Task.isCancelled && lifecycle == .connected {
            if outputBufferedBytes >= Self.outputHighWaterBytes {
                await waitForOutputDrain()
                if Task.isCancelled || lifecycle != .connected { break }
            }
            do {
                try await acquireLock(.libssh2)
            } catch {
                break
            }
            guard lifecycle == .connected, let ch = channel else {
                releaseLock(.libssh2)
                break
            }
            let receivedBefore = callbacks.received
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return libssh2_channel_read_ex(ch, 0, base.assumingMemoryBound(to: CChar.self), raw.count)
            }
            var err = n < 0 ? lastError() : nil
            // A clean end (EOF, exit signal, non-zero exit status) is not a transport error.
            var cleanEnd = false  // a plain `if`, not `&&`: its autoclosure would send `channel` across isolation
            if n <= 0 && n != Int(LIBSSH2_ERROR_EAGAIN) { cleanEnd = Self.channelEndedCleanly(ch, session: session) }
            let interest: SocketPoller.Interest = (n == Int(LIBSSH2_ERROR_EAGAIN)) ? blockInterest() : []
            let receivedAfter = callbacks.received
            releaseLock(.libssh2)
            if receivedAfter != receivedBefore {
                wakeForwardClients()
            }
            if cleanEnd { err = nil }

            if n > 0 {
                enqueueOutput(Data(buf[0..<n]))
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitOnSocket(interest: interest, timeoutMs: 250)
            } else {
                let exitError = (n == 0) ? nil : err
                if lifecycle == .connected {
                    Task { await self.teardown(error: exitError) }
                }
                break
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

    /// Test hook: verifies credentials were released after auth or teardown.
    internal var hasAuthForTesting: Bool { auth != nil }

    /// Last time a keepalive went out, and last time a probe saw the peer answer.
    private var lastKeepaliveSent: ContinuousClock.Instant?
    private var lastProofOfLife: ContinuousClock.Instant?

    /// Sends a keepalive that wants a reply, then waits for any inbound bytes (the reply, or any other
    /// traffic). On timeout or a send failure the connection tears down as `.disconnected(.timeout)`
    /// and this returns false. Cancelling the calling task abandons the probe without touching the
    /// connection. A probe within 3 s of a successful one returns true without sending.
    /// Concurrent probe calls share a single in-flight probe.
    public func probe(timeout: Duration) async -> Bool {
        guard lifecycle == .connected, session != nil, channel != nil else { return false }
        let now = ContinuousClock.now
        if let proof = lastProofOfLife, now - proof < .seconds(3) { return true }
        if Task.isCancelled { return lifecycle == .connected }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                guard lifecycle == .connected, session != nil, channel != nil else {
                    cont.resume(returning: false)
                    return
                }
                if let proof = lastProofOfLife, ContinuousClock.now - proof < .seconds(3) {
                    cont.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    cont.resume(returning: lifecycle == .connected)
                    return
                }
                probeContinuations[waiterID] = cont
                if probeTask == nil {
                    probeTask = Task { await self.runProbe(timeout: timeout) }
                }
            }
        } onCancel: {
            Task { await self.abandonProbeWaiter(id: waiterID) }
        }
    }

    private func abandonProbeWaiter(id: UUID) {
        guard let cont = probeContinuations.removeValue(forKey: id) else { return }
        cont.resume(returning: lifecycle == .connected)
        if probeContinuations.isEmpty {
            probeTask?.cancel()
            probeTask = nil
        }
    }

    private func runProbe(timeout: Duration) async {
        do {
            // libssh2 sends a keepalive only when `last_sent + interval <= time(NULL)` (whole seconds),
            // and returns 0 either way, so "did it send" cannot be read from its result. Waiting 3 s
            // after our previous send guarantees the next call sends.
            if let last = lastKeepaliveSent, ContinuousClock.now < last + .seconds(3) {
                try await Task.sleep(until: last + .seconds(3), clock: .continuous)
            }
            try Task.checkCancellation()
            guard lifecycle == .connected, session != nil, channel != nil else {
                finishProbe(result: false)
                return
            }
            // The reply budget starts now, after any wait above.
            let deadline = ContinuousClock.now + timeout
            // Known limit: bytes already sitting in the kernel buffer from before a suspension can be
            // read after this baseline, so a half-open link can pass one probe; the next one catches it.
            let baseline = callbacks.received
            let (rc, _) = try await perform(deadline: deadline) {
                guard let s = self.session else { return Int(LIBSSH2_ERROR_BAD_USE) }
                var next: Int32 = 0
                libssh2_keepalive_config(s, 1, 2)
                return Int(libssh2_keepalive_send(s, &next))
            }
            lastKeepaliveSent = ContinuousClock.now
            if rc != 0 {
                await teardown(error: .timeout)
                finishProbe(result: false)
                return
            }
            while callbacks.received == baseline {
                try Task.checkCancellation()
                guard lifecycle == .connected else {
                    finishProbe(result: false)
                    return
                }
                if ContinuousClock.now >= deadline {
                    await teardown(error: .timeout)
                    finishProbe(result: false)
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            lastProofOfLife = ContinuousClock.now
            finishProbe(result: lifecycle == .connected)
        } catch {
            if error is CancellationError || Task.isCancelled {
                finishProbe(result: lifecycle == .connected)  // abandoned, not dead
            } else {
                await teardown(error: .timeout)
                finishProbe(result: false)
            }
        }
    }

    private func finishProbe(result: Bool) {
        probeTask = nil
        let waiting = probeContinuations
        probeContinuations.removeAll()
        for cont in waiting.values {
            cont.resume(returning: result)
        }
    }

    // MARK: Lock & non-blocking driver

    private func acquireLock(
        _ kind: LockKind,
        deadline: ContinuousClock.Instant? = nil,
        cancellable: Bool = true
    ) async throws {
        let state = lockStates[kind]!
        if cancellable { try Task.checkCancellation() }
        if let deadline, ContinuousClock.now >= deadline { throw SSHError.timeout }
        if !state.locked {
            state.locked = true
            return
        }
        let waiter = LockWaiter()
        let waiterID = waiter.id
        state.waiters.append(waiter)
        if let deadline {
            waiter.timeoutTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.expireLockWaiter(kind, id: waiterID)
            }
        }
        if cancellable {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if waiter.settled || Task.isCancelled {
                        if !waiter.settled {
                            waiter.settled = true
                            state.waiters.removeAll { $0.id == waiterID }
                            waiter.timeoutTask?.cancel()
                            waiter.timeoutTask = nil
                        }
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    waiter.continuation = cont
                }
            } onCancel: {
                Task { await self.cancelLockWaiter(kind, id: waiterID) }
            }
        } else {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiter.continuation = cont
            }
        }
    }

    private func cancelLockWaiter(_ kind: LockKind, id: UUID) {
        guard let state = lockStates[kind],
              let idx = state.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = state.waiters.remove(at: idx)
        guard !waiter.settled else { return }
        waiter.settled = true
        waiter.timeoutTask?.cancel()
        waiter.timeoutTask = nil
        let cont = waiter.continuation
        waiter.continuation = nil
        cont?.resume(throwing: CancellationError())
    }

    private func expireLockWaiter(_ kind: LockKind, id: UUID) {
        guard let state = lockStates[kind],
              let idx = state.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = state.waiters.remove(at: idx)
        guard !waiter.settled else { return }
        waiter.settled = true
        waiter.timeoutTask = nil
        let cont = waiter.continuation
        waiter.continuation = nil
        cont?.resume(throwing: SSHError.timeout)
    }

    private func releaseLock(_ kind: LockKind) {
        guard let state = lockStates[kind] else { return }
        while !state.waiters.isEmpty {
            let next = state.waiters.removeFirst()
            guard !next.settled, let cont = next.continuation else { continue }
            next.settled = true
            next.timeoutTask?.cancel()
            next.timeoutTask = nil
            next.continuation = nil
            cont.resume(returning: ())
            return
        }
        state.locked = false
    }

    private func blockInterest() -> SocketPoller.Interest {
        guard let s = session else { return [.read, .write] }
        let dirs = libssh2_session_block_directions(s)
        var interest: SocketPoller.Interest = []
        if dirs & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { interest.insert(.read) }
        if dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { interest.insert(.write) }
        return interest.isEmpty ? [.read, .write] : interest
    }

    private func registerSocketWait(_ flag: SocketPoller.CancelFlag) -> UUID {
        let id = UUID()
        activeSocketWaits[id] = flag
        return id
    }

    private func unregisterSocketWait(_ id: UUID) {
        activeSocketWaits.removeValue(forKey: id)
        if activeSocketWaits.isEmpty && !socketWaitDrainContinuations.isEmpty {
            let waiters = socketWaitDrainContinuations
            socketWaitDrainContinuations.removeAll()
            for w in waiters { w.resume() }
        }
    }

    private func waitOnSocket(interest: SocketPoller.Interest, timeoutMs: Int32) async {
        guard fd >= 0, lifecycle == .connecting || lifecycle == .connected else { return }
        let currentFd = fd
        let flag = SocketPoller.CancelFlag()
        let id = registerSocketWait(flag)
        await SocketPoller.wait(fd: currentFd, interest: interest, timeoutMs: timeoutMs, cancelFlag: flag)
        unregisterSocketWait(id)
    }

    private func effectiveDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        // Time the user spent answering a keyboard-interactive prompt does not count.
        var effective = deadline
        if let answered = kbd.lastAnswered(), answered + .seconds(30) > effective {
            effective = answered + .seconds(30)
        }
        return effective
    }

    private func remainingPollMs(deadline: ContinuousClock.Instant?) -> Int32 {
        guard let deadline else { return 250 }
        let rem = effectiveDeadline(deadline) - ContinuousClock.now
        guard rem > .zero else { return 0 }
        let (sec, atto) = rem.components
        let ms = sec * 1_000 + (atto + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(min(max(ms, 1), 250))
    }

    private func waitSocket(interest: SocketPoller.Interest, deadline: ContinuousClock.Instant?) async throws {
        let timeoutMs = remainingPollMs(deadline: deadline)
        if timeoutMs <= 0 { throw SSHError.timeout }
        await waitOnSocket(interest: interest, timeoutMs: timeoutMs)
        try Task.checkCancellation()
        guard lifecycle == .connecting || lifecycle == .connected else { throw SSHError.closed }
        if let deadline, ContinuousClock.now > effectiveDeadline(deadline) {
            throw SSHError.timeout
        }
    }

    /// Runs `op` until it stops returning EAGAIN, releasing the libssh2 lock while waiting on socket readiness.
    private func perform(deadline: ContinuousClock.Instant? = nil, _ op: () -> Int) async throws -> (rc: Int, error: SSHError?) {
        while true {
            try Task.checkCancellation()
            try await acquireLock(.libssh2, deadline: deadline)
            let rc: Int
            let error: SSHError?
            let interest: SocketPoller.Interest
            do {
                guard lifecycle == .connecting || lifecycle == .connected else {
                    releaseLock(.libssh2)
                    throw SSHError.closed
                }
                rc = op()
                if rc != Int(LIBSSH2_ERROR_EAGAIN) {
                    error = rc < 0 ? lastError() : nil
                    releaseLock(.libssh2)
                    return (rc, error)
                }
                interest = blockInterest()
            }
            releaseLock(.libssh2)
            try await waitSocket(interest: interest, deadline: deadline)
        }
    }

    private func performPointer(deadline: ContinuousClock.Instant? = nil, _ op: () -> OpaquePointer?) async throws -> OpaquePointer {
        while true {
            try Task.checkCancellation()
            try await acquireLock(.libssh2, deadline: deadline)
            let interest: SocketPoller.Interest
            do {
                guard lifecycle == .connecting || lifecycle == .connected else {
                    releaseLock(.libssh2)
                    throw SSHError.closed
                }
                if let p = op() {
                    releaseLock(.libssh2)
                    return p
                }
                guard let s = session, libssh2_session_last_errno(s) == LIBSSH2_ERROR_EAGAIN else {
                    let err = lastError()
                    releaseLock(.libssh2)
                    throw err
                }
                interest = blockInterest()
            }
            releaseLock(.libssh2)
            try await waitSocket(interest: interest, deadline: deadline)
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
        if let existing = teardownTask {
            await existing.value
            return
        }
        guard lifecycle != .closed else { return }
        lifecycle = .closing
        kbd.cancel()
        readLoopTask?.cancel()
        let task = Task { await self.performTeardown(error: error) }
        teardownTask = task
        await task.value
    }

    private func performTeardown(error: SSHError?) async {
        negotiated = nil
        auth = nil
        probeTask?.cancel()
        finishProbe(result: false)

        if error != nil, fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        for flag in activeSocketWaits.values { flag.cancel() }
        resumeOutputDrainWaiters()
        await readLoopTask?.value
        readLoopTask = nil

        await stopAllForwardsForTeardown()

        try? await acquireLock(.sftp, cancellable: false)
        try? await acquireLock(.libssh2, cancellable: false)

        if error == nil {
            let bound = ContinuousClock.now + .seconds(2)
            if let sftp = sftpSession {
                if await drain(until: bound, { libssh2_sftp_shutdown(sftp) }) == false {
                    if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
                    _ = libssh2_sftp_shutdown(sftp)
                }
                sftpSession = nil
            }
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
        } else {
            // Transport error / timeout: skip the 2 s graceful drain and tear down immediately.
            if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            if let sftp = sftpSession {
                _ = libssh2_sftp_shutdown(sftp)
                sftpSession = nil
            }
            if let channel {
                _ = libssh2_channel_free(channel)
                self.channel = nil
            }
            if let s = session {
                _ = libssh2_session_free(s)
                session = nil
            }
        }

        for flag in activeSocketWaits.values { flag.cancel() }
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        if !activeSocketWaits.isEmpty {
            await withCheckedContinuation { socketWaitDrainContinuations.append($0) }
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }

        releaseLock(.libssh2)
        releaseLock(.sftp)
        lifecycle = .closed
        teardownTask = nil
        finishOutput()
        stateCont.yield(.disconnected(error))
        stateCont.finish()
    }

    /// Repeats a non-blocking libssh2 close/free call through EAGAIN until `until`.
    /// Returns false if it was still EAGAIN at the deadline.
    @discardableResult
    private func drain(until deadline: ContinuousClock.Instant, _ op: () -> Int32) async -> Bool {
        while true {
            if op() != LIBSSH2_ERROR_EAGAIN { return true }
            if ContinuousClock.now >= deadline || fd < 0 { return false }
            let interest = blockInterest()
            await SocketPoller.wait(fd: fd, interest: interest, timeoutMs: 50)
        }
    }
}
