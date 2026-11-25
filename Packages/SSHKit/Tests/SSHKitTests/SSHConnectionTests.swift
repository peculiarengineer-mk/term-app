import XCTest
import Foundation
import Darwin
@testable import SSHKit

final class SSHConnectionTests: XCTestCase {
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

    func testWriteAndResizeBeforeConnectThrowNotConnected() async {
        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"))
        do {
            try await conn.write(Data("hello".utf8))
            XCTFail("Expected notConnected")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.resize(cols: 80, rows: 24)
            XCTFail("Expected notConnected")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await conn.close()
    }

    func testProbeAndAlgorithmsBeforeConnect() async {
        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"))
        let alive = await conn.probe(timeout: .milliseconds(100))
        XCTAssertFalse(alive)
        let algs = await conn.negotiatedAlgorithms()
        XCTAssertNil(algs)
        await conn.close()
    }

    func testDimensionClamping() async {
        XCTAssertEqual(SSHConnection.clampDimension(0), 1)
        XCTAssertEqual(SSHConnection.clampDimension(-10), 1)
        XCTAssertEqual(SSHConnection.clampDimension(Int.min), 1)
        XCTAssertEqual(SSHConnection.clampDimension(80), 80)
        XCTAssertEqual(SSHConnection.clampDimension(65535), 65535)
        XCTAssertEqual(SSHConnection.clampDimension(100_000), 65535)
        XCTAssertEqual(SSHConnection.clampDimension(Int.max), 65535)

        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"), cols: Int.max, rows: -5)
        do {
            try await conn.resize(cols: 0, rows: Int.max)
            XCTFail("Expected notConnected")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await conn.close()
    }

    func testCloseBeforeConnectFinishesStreamsAndRejectsConnect() async throws {
        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"))
        let hadAuthBefore = await conn.hasAuthForTesting
        XCTAssertTrue(hadAuthBefore)
        await conn.close()
        await conn.close()
        let hasAuthAfter = await conn.hasAuthForTesting
        XCTAssertFalse(hasAuthAfter)

        var states: [SessionState] = []
        for await s in conn.state { states.append(s) }
        XCTAssertEqual(states, [.disconnected(nil)])

        var chunks: [Data] = []
        for await c in conn.output { chunks.append(c) }
        XCTAssertTrue(chunks.isEmpty)

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected closed")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testSecondConnectRejectedAfterFailure() async throws {
        let port = try unusedLocalPort()
        let conn = SSHConnection(host: "127.0.0.1", port: port, username: "u", auth: .password("p"))
        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let hasAuthAfter = await conn.hasAuthForTesting
        XCTAssertFalse(hasAuthAfter)

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected closed on second connect")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testCancelConnectWhileHandshakingCleansUp() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }
        let accepted = Task.detached { () -> Int32 in
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 2_000) > 0 else { return -1 }
            return Darwin.accept(listener, nil, nil)
        }
        let conn = SSHConnection(host: "127.0.0.1", port: port, username: "u", auth: .password("p"))
        let states = conn.state
        let sawConnecting = Task {
            for await s in states {
                if case .connecting = s { return true }
                if case .disconnected = s { return false }
            }
            return false
        }
        let connectTask = Task {
            try await conn.connect { _ in .trust }
        }
        let didEnterConnecting = await sawConnecting.value
        XCTAssertTrue(didEnterConnecting)
        let peerFd = await accepted.value
        XCTAssertGreaterThanOrEqual(peerFd, 0)
        connectTask.cancel()
        do {
            try await connectTask.value
            XCTFail("Expected closed after cancellation")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
        let hasAuthAfter = await conn.hasAuthForTesting
        XCTAssertFalse(hasAuthAfter)
        if peerFd >= 0 { Darwin.close(peerFd) }
    }

    func testConcurrentSecondConnectRejectedWithoutTearingDownFirst() async throws {
        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }

        // Accept one connection and hold it open without sending an SSH banner so `connect()` waits in `.connecting`.
        let accepted = Task.detached { () -> Int32 in
            Darwin.accept(listener, nil, nil)
        }
        let conn = SSHConnection(host: "127.0.0.1", port: port, username: "u", auth: .password("p"))

        let states = conn.state
        let sawConnecting = Task {
            for await s in states {
                if case .connecting = s { return true }
                if case .disconnected = s { return false }
            }
            return false
        }

        let firstConnect = Task {
            try await conn.connect { _ in .trust }
        }

        let didEnterConnecting = await sawConnecting.value
        XCTAssertTrue(didEnterConnecting)

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected concurrent connect to fail")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // First connect should still be in progress until we close the connection.
        await conn.close()
        do {
            try await firstConnect.value
            XCTFail("Expected first connect to fail with .closed after close()")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }

        let peerFd = await accepted.value
        if peerFd >= 0 { Darwin.close(peerFd) }
    }
}
