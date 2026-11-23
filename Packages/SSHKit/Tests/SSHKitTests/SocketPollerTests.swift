import XCTest
import Darwin
@testable import SSHKit

final class SocketPollerTests: XCTestCase {
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

    func testConnectSucceedsOnLocalhost() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }
        let fd = try await SocketPoller.connect(host: "127.0.0.1", port: port, timeoutMs: 2_000)
        XCTAssertGreaterThanOrEqual(fd, 0)
        Darwin.close(fd)
    }

    func testConnectUnreachablePortThrowsConnectionFailed() async throws {
        let port = try unusedLocalPort()
        do {
            let fd = try await SocketPoller.connect(host: "127.0.0.1", port: port, timeoutMs: 2_000)
            Darwin.close(fd)
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected SSHError: \(error)")
            }
        }
    }

    func testConnectExhaustedBudgetTimesOut() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }
        do {
            let fd = try await SocketPoller.connect(host: "127.0.0.1", port: port, timeoutMs: 0)
            Darwin.close(fd)
            XCTFail("Expected timeout")
        } catch let error as SSHError {
            XCTAssertEqual(error, .connectionFailed("timed out"))
        }
    }

    func testConnectRespectsTaskCancellation() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }
        let task = Task {
            try await SocketPoller.connect(host: "127.0.0.1", port: port, timeoutMs: 5_000)
        }
        task.cancel()
        do {
            let fd = try await task.value
            Darwin.close(fd)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    func testWaitTimeoutAndCancellationOnPipe() async throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer { Darwin.close(readFd); Darwin.close(writeFd) }

        let start = ContinuousClock.now
        await SocketPoller.wait(fd: readFd, interest: .read, timeoutMs: 60)
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(40))
        XCTAssertLessThan(elapsed, .seconds(2))

        let cancelStart = ContinuousClock.now
        let waitTask = Task {
            await SocketPoller.wait(fd: readFd, interest: .read, timeoutMs: 5_000)
        }
        try await Task.sleep(for: .milliseconds(30))
        waitTask.cancel()
        await waitTask.value
        XCTAssertLessThan(ContinuousClock.now - cancelStart, .seconds(1))
    }

    func testPollUntilReadyTimeoutAndCancellation() async throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer { Darwin.close(readFd); Darwin.close(writeFd) }

        let timeoutFlag = SocketPoller.CancelFlag()
        let timeoutResult = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let rc = SocketPoller.pollUntilReady(
                    fd: readFd,
                    events: Int16(POLLIN),
                    deadline: ContinuousClock.now + .milliseconds(40),
                    cancelFlag: timeoutFlag
                )
                cont.resume(returning: rc)
            }
        }
        XCTAssertEqual(timeoutResult, 0)

        let cancelFlag = SocketPoller.CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
            cancelFlag.cancel()
        }
        let start = ContinuousClock.now
        let cancelResult = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let rc = SocketPoller.pollUntilReady(
                    fd: readFd,
                    events: Int16(POLLIN),
                    deadline: ContinuousClock.now + .seconds(5),
                    cancelFlag: cancelFlag
                )
                cont.resume(returning: rc)
            }
        }
        XCTAssertEqual(cancelResult, -2)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }
}
