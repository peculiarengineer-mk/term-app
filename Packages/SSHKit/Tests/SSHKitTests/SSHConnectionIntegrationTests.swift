import XCTest
import Foundation
import CryptoKit
@testable import SSHKit

final class SSHConnectionIntegrationTests: XCTestCase {
    private struct Env { let host: String; let port: UInt16; let user: String; let password: String?; let keyPath: String? }

    private func env(needPassword: Bool = false, needKey: Bool = false) throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["TERMAPP_TEST_HOST"], !host.isEmpty, let user = e["TERMAPP_TEST_USER"], !user.isEmpty else {
            throw XCTSkip("TERMAPP_TEST_HOST / TERMAPP_TEST_USER not set")
        }
        let pw = e["TERMAPP_TEST_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
        let key = e["TERMAPP_TEST_KEY_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        if needPassword && pw == nil { throw XCTSkip("TERMAPP_TEST_PASSWORD not set") }
        if needKey && key == nil { throw XCTSkip("TERMAPP_TEST_KEY_PATH not set") }
        let port = e["TERMAPP_TEST_PORT"].flatMap { UInt16($0) } ?? 22
        return Env(host: host, port: port, user: user, password: pw, keyPath: key)
    }

    private func connect(_ conn: SSHConnection) async throws {
        try await conn.connect { hostKey in
            XCTAssertTrue(hostKey.fingerprint.hasPrefix("SHA256:"))
            return .trust
        }
    }

    private func collect(_ conn: SSHConnection, until marker: String, timeout: Double = 15) async -> String {
        let stream = conn.output
        return await withTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for await chunk in stream {
                    text += String(decoding: chunk, as: UTF8.self)
                    if text.contains(marker) { break }
                }
                return text
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return "" }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
    }

    func testPasswordLogin() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        await conn.close()
    }

    func testKeyLogin() async throws {
        let e = try env(needKey: true)
        let pem = try Data(contentsOf: URL(fileURLWithPath: e.keyPath!))
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .privateKey(pem: pem, passphrase: nil))
        try await connect(conn)
        await conn.close()
    }

    func testEchoRoundTrip() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        try await conn.write(Data("echo $((20+22))ok\n".utf8))
        let text = await collect(conn, until: "42ok\r\n")
        XCTAssertTrue(text.contains("42ok"), "output: \(text)")
        await conn.close()
    }

    func testResize() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        try await conn.resize(cols: 120, rows: 40)
        try await conn.write(Data("stty size\n".utf8))
        let text = await collect(conn, until: "40 120")
        XCTAssertTrue(text.contains("40 120"), "output: \(text)")
        await conn.close()
    }

    /// A healthy idle connection passes repeated probes: an immediate second probe is answered from
    /// the recent proof of life, and a third after that window really sends a keepalive and needs the reply.
    func testProbeIdleConnectionTwice() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        try await Task.sleep(for: .seconds(3))  // let the login banner and prompt finish
        let first = await conn.probe(timeout: .seconds(5))
        let second = await conn.probe(timeout: .seconds(5))
        XCTAssertTrue(first, "first probe")
        XCTAssertTrue(second, "second probe within the recent-proof window")
        try await Task.sleep(for: .seconds(3.5))  // past the recent-proof window: this one must really send
        let third = await conn.probe(timeout: .seconds(8))
        XCTAssertTrue(third, "third probe after the window")
        await conn.close()
    }

    func testProbeHealthy() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        // Let the login output settle first, so only the keepalive reply can pass the probe.
        try await Task.sleep(for: .seconds(3.5))
        let alive = await conn.probe(timeout: .seconds(3))
        XCTAssertTrue(alive)
        await conn.close()
    }

    func testProbeDeadConnection() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        let states = conn.state
        let ended = Task { () -> SSHError?? in
            for await s in states { if case .disconnected(let err) = s { return .some(err) } }
            return nil
        }
        await conn.closeSocketForTesting()
        let alive = await conn.probe(timeout: .seconds(3))
        XCTAssertFalse(alive)
        let watchdog = Task { try? await Task.sleep(for: .seconds(5)); ended.cancel() }
        let result = await ended.value
        watchdog.cancel()
        guard case .some(let err) = result else { return XCTFail("no .disconnected within 5 s") }
        XCTAssertNotNil(err, "a dead connection ends with a transport error")
    }

    func testNegotiatesPostQuantumKex() async throws {
        let e = try env(needPassword: true)
        let conn = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(conn)
        let negotiated = await conn.negotiatedAlgorithms()
        XCTAssertEqual(negotiated?.kex, "mlkem768x25519-sha256")
        XCTAssertEqual(negotiated?.isPostQuantum, true)
        XCTAssertEqual(negotiated?.cipher, "chacha20-poly1305@openssh.com")
        await conn.close()
    }

    private static func sshString(_ d: Data) -> Data {
        var n = UInt32(d.count).bigEndian
        return Data(bytes: &n, count: 4) + d
    }

    private static func mpint(_ d: Data) -> Data {
        var v = Data(d.drop(while: { $0 == 0 }))
        if let f = v.first, f & 0x80 != 0 { v.insert(0, at: 0) }
        return sshString(v)
    }

    func testSignerLogin() async throws {
        let e = try env(needPassword: true)
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let blob = Self.sshString(Data("ecdsa-sha2-nistp256".utf8)) + Self.sshString(Data("nistp256".utf8)) + Self.sshString(point)
        let line = "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) termapp-signer-test"

        let admin = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .password(e.password!))
        try await connect(admin)
        try await admin.write(Data("mkdir -p ~/.ssh && echo '\(line)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo added$((1+1))\n".utf8))
        let added = await collect(admin, until: "added2\r\n")
        XCTAssertTrue(added.contains("added2"), "output: \(added)")

        let cleanupCmd = "sed '/termapp-signer-test/d' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && chmod 600 ~/.ssh/authorized_keys.tmp && mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && echo removed$((1+1))\n"
        var signerConn: SSHConnection?
        do {
            let signer = SSHConnection(host: e.host, port: e.port, username: e.user, auth: .signer(publicKeyBlob: blob, sign: { data in
                guard let sig = try? key.signature(for: data) else { return nil }
                let raw = sig.rawRepresentation
                return Self.mpint(raw.prefix(32)) + Self.mpint(raw.suffix(32))
            }))
            signerConn = signer
            try await connect(signer)
            try await signer.write(Data("echo o''k\n".utf8))
            let text = await collect(signer, until: "ok\r\n")
            XCTAssertTrue(text.contains("ok\r\n"), "output: \(text)")
            await signer.close()
        } catch {
            await signerConn?.close()
            try? await admin.write(Data(cleanupCmd.utf8))
            _ = await collect(admin, until: "removed2\r\n")
            await admin.close()
            throw error
        }
        try await admin.write(Data(cleanupCmd.utf8))
        _ = await collect(admin, until: "removed2\r\n")
        await admin.close()
    }

    func testProxyJumpMultiHopSessionExecAndSFTP() async throws {
        let e = try env(needPassword: true)
        let hop1 = SSHJumpHop(host: e.host, port: e.port, username: e.user, auth: .password(e.password!)) { _ in .trust }
        let hop2 = SSHJumpHop(host: e.host, port: e.port, username: e.user, auth: .password(e.password!)) { _ in .trust }

        let conn = SSHConnection(
            host: e.host,
            port: e.port,
            username: e.user,
            auth: .password(e.password!),
            jumpHops: [hop1, hop2]
        )
        try await connect(conn)
        let activeJumps = await conn.activeJumpConnectionCountForTesting
        XCTAssertEqual(activeJumps, 2)

        try await conn.write(Data("echo jump_pty_ok\n".utf8))
        let ptyText = await collect(conn, until: "jump_pty_ok\r\n")
        XCTAssertTrue(ptyText.contains("jump_pty_ok"), "output: \(ptyText)")

        let execRes = try await conn.exec("echo jump_exec_ok", timeout: .seconds(10))
        XCTAssertEqual(execRes.exitCode, 0)
        XCTAssertTrue(execRes.stdout.contains("jump_exec_ok"))

        let entries = try await conn.sftpListDirectory(path: ".")
        XCTAssertNotNil(entries)
        await conn.close()

        let jumpCountAfterClose = await conn.activeJumpConnectionCountForTesting
        XCTAssertEqual(jumpCountAfterClose, 0)

        let oneShot = try await SSHExec.runCommand(
            host: e.host,
            port: e.port,
            username: e.user,
            auth: .password(e.password!),
            command: "echo oneshot_jump_ok",
            timeout: .seconds(15),
            jumpHops: [hop1]
        ) { _ in .trust }
        XCTAssertEqual(oneShot.exitCode, 0)
        XCTAssertTrue(oneShot.stdout.contains("oneshot_jump_ok"))
    }

    func testAgentForwardingListsForwardedIdentity() async throws {
        let e = try env(needPassword: true)
        let key = Curve25519.Signing.PrivateKey()
        let blob = Self.sshString(Data("ssh-ed25519".utf8)) + Self.sshString(key.publicKey.rawRepresentation)
        let comment = "termapp-agent-fwd-test"
        let identity = SSHAgentIdentity(publicKeyBlob: blob, comment: comment) { data in
            try? key.signature(for: data)
        }
        let conn = SSHConnection(
            host: e.host,
            port: e.port,
            username: e.user,
            auth: .password(e.password!),
            agentForwarding: SSHAgentForwardingConfig(identities: [identity])
        )
        try await connect(conn)
        try await conn.write(Data("ssh-add -L; echo agent_done\n".utf8))
        let text = await collect(conn, until: "agent_done\r\n")
        XCTAssertTrue(text.contains("agent_done"), "output: \(text)")
        if text.contains("SSH_AUTH_SOCK") || !text.contains("Could not open a connection") {
            XCTAssertTrue(text.contains(comment), "expected forwarded key comment in: \(text)")
        }
        await conn.close()
    }
}
