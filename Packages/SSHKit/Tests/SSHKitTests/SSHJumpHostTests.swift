import XCTest
import Foundation
import Darwin
@testable import SSHKit

final class SSHJumpHostTests: XCTestCase {
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

    func testSSHJumpHopDefaultsAndValidation() throws {
        let hop = SSHJumpHop(host: "bastion.example.com", username: "jumpuser", auth: .password("pw")) { _ in .trust }
        XCTAssertEqual(hop.host, "bastion.example.com")
        XCTAssertEqual(hop.port, 22)
        XCTAssertEqual(hop.username, "jumpuser")

        XCTAssertNoThrow(try SSHJumpValidator.validate([hop]))
        XCTAssertThrowsError(
            try SSHJumpValidator.validate([SSHJumpHop(host: "   ", port: 22, username: "u", auth: .password("p")) { _ in .trust }])
        )
        XCTAssertThrowsError(
            try SSHJumpValidator.validate([SSHJumpHop(host: "bastion", port: 0, username: "u", auth: .password("p")) { _ in .trust }])
        )
    }

    func testInvalidJumpHopFailsAndPreservesTargetEndpointAndCleansUp() async throws {
        let invalidHop = SSHJumpHop(host: "", port: 22, username: "u", auth: .password("p")) { _ in .trust }
        let conn = SSHConnection(
            host: "target.internal",
            port: 2222,
            username: "targetuser",
            auth: .password("p"),
            jumpHops: [invalidHop]
        )
        let endpoint = await conn.targetEndpointForTesting()
        XCTAssertEqual(endpoint.host, "target.internal")
        XCTAssertEqual(endpoint.port, 2222)

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let jumpCount = await conn.activeJumpConnectionCountForTesting
        XCTAssertEqual(jumpCount, 0)

        var states: [SessionState] = []
        for await s in conn.state { states.append(s) }
        guard case .connecting = states.first, case .disconnected(let endErr) = states.last, endErr != nil else {
            return XCTFail("Unexpected state stream: \(states)")
        }
    }

    func testUnreachableJumpHopCleansUpAndRejectsSecondConnect() async throws {
        let closedPort = try unusedLocalPort()
        let hop = SSHJumpHop(host: "127.0.0.1", port: closedPort, username: "u", auth: .password("p")) { _ in .trust }
        let conn = SSHConnection(
            host: "target.internal",
            port: 22,
            username: "u",
            auth: .password("p"),
            jumpHops: [hop]
        )

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let jumpCount = await conn.activeJumpConnectionCountForTesting
        XCTAssertEqual(jumpCount, 0)

        do {
            try await conn.connect { _ in .trust }
            XCTFail("Expected closed on second connect")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testCloseAndCancelDuringJumpHandshakeCleanUpJumpConnections() async throws {
        let (listener1, port1) = try makeListeningSocket()
        defer { Darwin.close(listener1) }
        let accepted1 = Task.detached { () -> Int32 in
            var pfd = pollfd(fd: listener1, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 2_000) > 0 else { return -1 }
            return Darwin.accept(listener1, nil, nil)
        }

        let hop1 = SSHJumpHop(host: "127.0.0.1", port: port1, username: "u", auth: .password("p")) { _ in .trust }
        let conn1 = SSHConnection(host: "internal.host", port: 22, username: "u", auth: .password("p"), jumpHops: [hop1])
        let task1 = Task { try await conn1.connect { _ in .trust } }
        let peer1 = await accepted1.value
        XCTAssertGreaterThanOrEqual(peer1, 0)

        task1.cancel()
        do {
            try await task1.value
            XCTFail("Expected SSHError.closed")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
        let count1 = await conn1.activeJumpConnectionCountForTesting
        XCTAssertEqual(count1, 0)
        if peer1 >= 0 { Darwin.close(peer1) }

        // Test external close() while jump hop is mid-handshake.
        let (listener2, port2) = try makeListeningSocket()
        defer { Darwin.close(listener2) }
        let accepted2 = Task.detached { () -> Int32 in
            var pfd = pollfd(fd: listener2, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 2_000) > 0 else { return -1 }
            return Darwin.accept(listener2, nil, nil)
        }
        let hop2 = SSHJumpHop(host: "127.0.0.1", port: port2, username: "u", auth: .password("p")) { _ in .trust }
        let conn2 = SSHConnection(host: "internal.host", port: 22, username: "u", auth: .password("p"), jumpHops: [hop2])
        let task2 = Task { try await conn2.connect { _ in .trust } }
        let peer2 = await accepted2.value
        XCTAssertGreaterThanOrEqual(peer2, 0)

        await conn2.close()
        do {
            try await task2.value
            XCTFail("Expected SSHError.closed")
        } catch let error as SSHError {
            XCTAssertEqual(error, .closed)
        }
        let count2 = await conn2.activeJumpConnectionCountForTesting
        XCTAssertEqual(count2, 0)
        if peer2 >= 0 { Darwin.close(peer2) }
    }

    func testSSHExecRunCommandWithJumpHopsRespectsTimeoutAndUnreachableHop() async throws {
        let closedPort = try unusedLocalPort()
        let badHop = SSHJumpHop(host: "127.0.0.1", port: closedPort, username: "u", auth: .password("p")) { _ in .trust }
        do {
            _ = try await SSHExec.runCommand(
                host: "internal.host",
                port: 22,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .seconds(2),
                jumpHops: [badHop]
            ) { _ in .trust }
            XCTFail("Expected connectionFailed")
        } catch let error as SSHError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let (listener, port) = try makeListeningSocket()
        defer { Darwin.close(listener) }
        let accepted = Task.detached { () -> Int32 in
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 2_000) > 0 else { return -1 }
            return Darwin.accept(listener, nil, nil)
        }
        let silentHop = SSHJumpHop(host: "127.0.0.1", port: port, username: "u", auth: .password("p")) { _ in .trust }
        let start = ContinuousClock.now
        do {
            _ = try await SSHExec.runCommand(
                host: "internal.host",
                port: 22,
                username: "u",
                auth: .password("p"),
                command: "echo hi",
                timeout: .milliseconds(150),
                jumpHops: [silentHop]
            ) { _ in .trust }
            XCTFail("Expected timeout")
        } catch let error as SSHError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let peer = await accepted.value
        if peer >= 0 { Darwin.close(peer) }
    }
}
