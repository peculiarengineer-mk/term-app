import XCTest
import Foundation
import Darwin
@testable import SSHKit

final class SSHExecTests: XCTestCase {
    private func makeListeningSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindRc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRc == 0 else { Darwin.close(fd); throw XCTSkip("bind failed: \(errno)") }
        guard Darwin.listen(fd, 4) == 0 else { Darwin.close(fd); throw XCTSkip("listen failed: \(errno)") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRc = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameRc == 0 else { Darwin.close(fd); throw XCTSkip("getsockname failed") }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    private func unusedLocalPort() throws -> UInt16 {
        let (fd, port) = try makeListeningSocket()
        Darwin.close(fd)
        return port
    }

    func testSSHExecResultEqualityAndProperties() {
        let r1 = SSHExecResult(stdout: "main\n", stderr: "", exitCode: 0)
        let r2 = SSHExecResult(stdout: "main\n", stderr: "", exitCode: 0)
        let r3 = SSHExecResult(stdout: "", stderr: "no server running\n", exitCode: 1)
        XCTAssertEqual(r1, r2)
        XCTAssertNotEqual(r1, r3)
        XCTAssertEqual(r1.stdout, "main\n")
        XCTAssertEqual(r1.stderr, "")
        XCTAssertEqual(r1.exitCode, 0)
        XCTAssertEqual(r3.stderr, "no server running\n")
        XCTAssertEqual(r3.exitCode, 1)
    }

    func testExecBeforeConnectAndAfterCloseThrowsNotConnectedWithoutConsumingState() async {
        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"))

        do {
            _ = try await conn.exec("echo hi")
            XCTFail("Expected SSHError.notConnected before connect")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Verify Session protocol dynamic dispatch works too.
        let session: any Session = conn
        do {
            _ = try await session.exec("echo hi")
            XCTFail("Expected SSHError.notConnected via Session")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await conn.close()

        do {
            _ = try await conn.exec("echo hi", timeout: .seconds(2))
            XCTFail("Expected SSHError.notConnected after close")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Single-consumer `state` stream must remain intact and unconsumed by `exec`.
        var states: [SessionState] = []
        for await s in conn.state {
            states.append(s)
        }
        XCTAssertEqual(states, [.disconnected(nil)])
    }

    func testDefaultSessionExecUnsupported() async {
        let session: any Session = StubUnsupportedExecSession()
        do {
            _ = try await session.exec("ls")
            XCTFail("Expected SSHError.channelFailed")
        } catch let error as SSHError {
            guard case .channelFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOutputAccumulatorUTF8ChunkSplittingAndCap() throws {
        var acc = SSHExecOutputAccumulator(maxBytes: 12)
        // 4-byte emoji "🚀" = [0xF0, 0x9F, 0x9A, 0x80] split across two reads.
        try acc.appendStdout([0xF0, 0x9F])
        try acc.appendStdout([0x9A, 0x80, 0x0A])
        try acc.appendStderr(Array("err\n".utf8))
        XCTAssertEqual(acc.totalBytes, 9)

        // Filling up to exact cap succeeds.
        try acc.appendStdout(Array("123".utf8))
        XCTAssertEqual(acc.totalBytes, 12)

        let result = acc.buildResult(exitCode: 0)
        XCTAssertEqual(result.stdout, "🚀\n123")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.exitCode, 0)

        // Exceeding cap on either stdout or stderr throws channelFailed.
        XCTAssertThrowsError(try acc.appendStderr([0x21])) { error in
            guard case SSHError.channelFailed = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(acc.totalBytes, 12)
    }

    func testSignalExitCodeMapping() {
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "HUP"), 129)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "INT"), 130)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "KILL"), 137)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "SIGKILL"), 137)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "term"), 143)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "SIGTERM\n"), 143)
        XCTAssertEqual(SSHExecSignal.exitCode(forSignalName: "UNKNOWN"), -1)
    }

    func testRunCommandZeroTimeoutAndPreCancelled() async throws {
        do {
            _ = try await SSHExec.runCommand(
                host: "127.0.0.1",
                port: 22,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .zero
            ) { _ in .trust }
            XCTFail("Expected timeout")
        } catch let error as SSHError {
            XCTAssertEqual(error, .timeout)
        }

        let cancelledTask = Task {
            try await SSHExec.runCommand(
                host: "127.0.0.1",
                port: 22,
                username: "u",
                auth: .password("p"),
                command: "echo hi"
            ) { _ in .trust }
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    func testRunCommandUnreachablePortThrowsConnectionFailed() async throws {
        let port = try unusedLocalPort()
        do {
            _ = try await SSHExec.runCommand(
                host: "127.0.0.1",
                port: port,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .seconds(2)
            ) { _ in .trust }
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRunCommandTimeoutAndCancellationOnSilentListener() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }

        let accepted1 = Task.detached { () -> Int32 in
            acceptSocketWithTimeout(listener: listener)
        }
        let timeoutStart = ContinuousClock.now
        do {
            _ = try await SSHExec.runCommand(
                host: "127.0.0.1",
                port: port,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .milliseconds(150)
            ) { _ in .trust }
            XCTFail("Expected timeout")
        } catch let error as SSHError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(ContinuousClock.now - timeoutStart, .seconds(2))
        let peer1 = await accepted1.value
        if peer1 >= 0 { Darwin.close(peer1) }

        let accepted2 = Task.detached { () -> Int32 in
            acceptSocketWithTimeout(listener: listener)
        }
        let cancelStart = ContinuousClock.now
        let task = Task {
            try await SSHExec.runCommand(
                host: "127.0.0.1",
                port: port,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .seconds(10)
            ) { _ in .trust }
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertLessThan(ContinuousClock.now - cancelStart, .seconds(2))
        let peer2 = await accepted2.value
        if peer2 >= 0 { Darwin.close(peer2) }
    }

    func testCancelConnectDuringHandshakeAndBeforeConnectCleansUp() async throws {
        // 1. Cancel immediately on `.connecting` (may cancel before TCP connect completes)
        let (listener1, port1) = try makeListeningSocket()
        defer { Darwin.close(listener1) }
        let accepted1 = Task.detached { () -> Int32 in
            acceptSocketWithTimeout(listener: listener1, timeoutMs: 500)
        }
        let conn1 = SSHConnection(host: "127.0.0.1", port: port1, username: "u", auth: .password("p"))
        let states1 = conn1.state
        let sawConnecting1 = Task {
            for await s in states1 {
                if case .connecting = s { return true }
                if case .disconnected = s { return false }
            }
            return false
        }
        let task1 = Task { try await conn1.connect { _ in .trust } }
        let entered1 = await sawConnecting1.value
        XCTAssertTrue(entered1)
        task1.cancel()
        do {
            try await task1.value
            XCTFail("Expected SSHError.closed")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
        let peer1 = await accepted1.value
        if peer1 >= 0 { Darwin.close(peer1) }

        // 2. Cancel strictly after TCP accept (guaranteed to be in libssh2 handshake)
        let (listener2, port2) = try makeListeningSocket()
        defer { Darwin.close(listener2) }
        let accepted2 = Task.detached { () -> Int32 in
            acceptSocketWithTimeout(listener: listener2, timeoutMs: 2_000)
        }
        let conn2 = SSHConnection(host: "127.0.0.1", port: port2, username: "u", auth: .password("p"))
        let task2 = Task { try await conn2.connect { _ in .trust } }
        let peer2 = await accepted2.value
        XCTAssertGreaterThanOrEqual(peer2, 0)
        try await Task.sleep(for: .milliseconds(30))
        task2.cancel()
        do {
            try await task2.value
            XCTFail("Expected SSHError.closed")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
        if peer2 >= 0 { Darwin.close(peer2) }
    }

    // MARK: Optional live SSH server tests (run when TERMAPP_TEST_* env vars are set)

    func testLiveExecAndConcurrentWithInteractivePTY() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["TERMAPP_TEST_HOST"], !host.isEmpty,
              let user = e["TERMAPP_TEST_USER"], !user.isEmpty,
              let password = e["TERMAPP_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("TERMAPP_TEST_HOST / TERMAPP_TEST_USER / TERMAPP_TEST_PASSWORD not set")
        }
        let port = e["TERMAPP_TEST_PORT"].flatMap { UInt16($0) } ?? 22

        let oneShot = try await SSHExec.runCommand(
            host: host,
            port: port,
            username: user,
            auth: .password(password),
            command: "printf 'out_ok'; printf 'err_ok' >&2; exit 7",
            timeout: .seconds(10)
        ) { _ in .trust }
        XCTAssertEqual(oneShot.stdout, "out_ok")
        XCTAssertEqual(oneShot.stderr, "err_ok")
        XCTAssertEqual(oneShot.exitCode, 7)

        let conn = SSHConnection(host: host, port: port, username: user, auth: .password(password))
        try await conn.connect { _ in .trust }
        let execRes = try await conn.exec("echo live_exec_ok", timeout: .seconds(10))
        XCTAssertEqual(execRes.exitCode, 0)
        XCTAssertTrue(execRes.stdout.contains("live_exec_ok"))

        do {
            _ = try await conn.exec("sleep 5", timeout: .milliseconds(250))
            XCTFail("Expected timeout")
        } catch let error as SSHError {
            XCTAssertEqual(error, .timeout)
        }

        // Interactive PTY must remain healthy after exec timeout.
        try await conn.write(Data("echo after_exec_pty_ok\n".utf8))
        let stream = conn.output
        let ptyText = await withTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for await chunk in stream {
                    text += String(decoding: chunk, as: UTF8.self)
                    if text.contains("after_exec_pty_ok") { break }
                }
                return text
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return "" }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        XCTAssertTrue(ptyText.contains("after_exec_pty_ok"))
        await conn.close()
    }
}

private func acceptSocketWithTimeout(listener: Int32, timeoutMs: Int32 = 2_000) -> Int32 {
    var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    let rc = Darwin.poll(&pfd, 1, timeoutMs)
    guard rc > 0 else { return -1 }
    return Darwin.accept(listener, nil, nil)
}

private final class StubUnsupportedExecSession: Session, @unchecked Sendable {
    let output: AsyncStream<Data> = AsyncStream { $0.finish() }
    let state: AsyncStream<SessionState> = AsyncStream { $0.finish() }
    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {}
}
