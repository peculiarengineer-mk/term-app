import XCTest
import Foundation
import SSHKit
@testable import Store

final class KeyGeneratorLoginTests: XCTestCase {
    func testGeneratedKeyLogsIn() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["TERMAPP_TEST_HOST"], !host.isEmpty, let user = e["TERMAPP_TEST_USER"], !user.isEmpty,
              let pw = e["TERMAPP_TEST_PASSWORD"], !pw.isEmpty else {
            throw XCTSkip("TERMAPP_TEST_HOST / USER / PASSWORD not set")
        }
        let port = e["TERMAPP_TEST_PORT"].flatMap { UInt16($0) } ?? 22
        let comment = "termapp-test-\(UUID().uuidString.prefix(8))"
        let g = try KeyGenerator.generateEd25519(comment: comment)

        // Append the public key over a password session.
        let setup = SSHConnection(host: host, port: port, username: user, auth: .password(pw))
        try await setup.connect { _ in .trust }
        let cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(g.publicLine)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys\n"
        try await setup.write(Data(cmd.utf8))
        try await Task.sleep(for: .seconds(2))
        await setup.close()

        var loginError: Error?
        do {
            let conn = SSHConnection(host: host, port: port, username: user, auth: .privateKey(pem: Data(g.privateKeyPEM.utf8), passphrase: nil))
            do { try await conn.connect { _ in .trust } } catch { loginError = error }
            await conn.close()
        }

        // Cleanup runs regardless of the login result; the comment is unique and contains no sed metacharacters.
        if let loginError { XCTFail("key login failed: \(loginError)") }  // reported even if cleanup throws
        let clean = SSHConnection(host: host, port: port, username: user, auth: .password(pw))
        try await clean.connect { _ in .trust }
        try await clean.write(Data("sed -i '/ \(comment)$/d' ~/.ssh/authorized_keys\n".utf8))
        try await Task.sleep(for: .seconds(1))
        await clean.close()
    }
}
