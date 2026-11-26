import XCTest
import Foundation
import Darwin
import CLibSSH2
@testable import SSHKit

final class SFTPAndForwardTests: XCTestCase {
    func testSFTPPathJoin() {
        XCTAssertEqual(SFTPPath.join("/", "etc"), "/etc")
        XCTAssertEqual(SFTPPath.join("/home/user", "file.txt"), "/home/user/file.txt")
        XCTAssertEqual(SFTPPath.join("/home/user/", "file.txt"), "/home/user/file.txt")
        XCTAssertEqual(SFTPPath.join("/home/user//", "file.txt"), "/home/user/file.txt")
        XCTAssertEqual(SFTPPath.join("/home/user", "/nested"), "/home/user/nested")
        XCTAssertEqual(SFTPPath.join("/home/user", ""), "/home/user")
        XCTAssertEqual(SFTPPath.join("/", ""), "/")
        XCTAssertEqual(SFTPPath.join("", "file.txt"), "file.txt")
        XCTAssertEqual(SFTPPath.join(".", "file.txt"), "./file.txt")
    }

    func testSFTPPathParent() {
        XCTAssertEqual(SFTPPath.parent(of: "/"), "/")
        XCTAssertEqual(SFTPPath.parent(of: "///"), "/")
        XCTAssertEqual(SFTPPath.parent(of: ""), "/")
        XCTAssertEqual(SFTPPath.parent(of: "/etc"), "/")
        XCTAssertEqual(SFTPPath.parent(of: "/etc/"), "/")
        XCTAssertEqual(SFTPPath.parent(of: "/home/user/file.txt"), "/home/user")
        XCTAssertEqual(SFTPPath.parent(of: "/home/user/"), "/home")
        XCTAssertEqual(SFTPPath.parent(of: "a/b"), "a")
        XCTAssertEqual(SFTPPath.parent(of: "single"), ".")
    }

    func testSFTPPathSortEntriesDirectoriesFirstCaseInsensitive() {
        let entries = [
            SFTPEntry(name: "zeta.txt", path: "/zeta.txt", isDirectory: false, size: 10),
            SFTPEntry(name: "alpha.txt", path: "/alpha.txt", isDirectory: false, size: 20),
            SFTPEntry(name: "Beta.txt", path: "/Beta.txt", isDirectory: false, size: 30),
            SFTPEntry(name: "src", path: "/src", isDirectory: true),
            SFTPEntry(name: "Docs", path: "/Docs", isDirectory: true),
            SFTPEntry(name: "bin", path: "/bin", isDirectory: true),
            SFTPEntry(name: "link", path: "/link", isDirectory: false, isSymlink: true),
        ]

        let sorted = SFTPPath.sortEntries(entries)
        XCTAssertEqual(
            sorted.map(\.name),
            ["bin", "Docs", "src", "alpha.txt", "Beta.txt", "link", "zeta.txt"]
        )
        XCTAssertEqual(sorted.prefix(3).allSatisfy(\.isDirectory), true)
        XCTAssertEqual(sorted.dropFirst(3).allSatisfy { !$0.isDirectory }, true)
    }

    func testSFTPEntryAndErrorModels() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = SFTPEntry(
            name: "notes.md",
            path: "/home/u/notes.md",
            isDirectory: false,
            isSymlink: false,
            size: 1024,
            permissions: 0o100644,
            modifiedAt: now
        )
        XCTAssertEqual(entry.id, "/home/u/notes.md")
        XCTAssertEqual(entry.size, 1024)
        XCTAssertEqual(entry.permissions, 0o100644)
        XCTAssertEqual(entry.modifiedAt, now)

        XCTAssertEqual(SFTPError.notConnected, .notConnected)
        XCTAssertEqual(SFTPError.fileTooLarge(42), .fileTooLarge(42))
        XCTAssertEqual(SFTPError.notFound("/missing"), .notFound("/missing"))
        XCTAssertEqual(SFTPError.permissionDenied("/root"), .permissionDenied("/root"))
    }

    func testPortForwardRuleSummaryAndActiveForwardLocalURL() throws {
        let rule = PortForwardRule(name: "Web", localPort: 8080, remoteHost: "127.0.0.1", remotePort: 3000)
        XCTAssertEqual(rule.summary, "127.0.0.1:8080 → 127.0.0.1:3000")

        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PortForwardRule.self, from: encoded)
        XCTAssertEqual(decoded, rule)

        let ephemeralRule = PortForwardRule(localPort: 0, remoteHost: "db.internal", remotePort: 5432)
        XCTAssertEqual(ephemeralRule.summary, "127.0.0.1:0 → db.internal:5432")

        let active = ActivePortForward(rule: ephemeralRule, boundLocalPort: 51234)
        XCTAssertEqual(active.id, ephemeralRule.id)
        XCTAssertEqual(active.localURL, URL(string: "http://127.0.0.1:51234"))
    }

    func testSFTPAndForwardStateGuardsBeforeConnectThrowNotConnected() async {
        let conn = SSHConnection(host: "127.0.0.1", username: "u", auth: .password("p"))

        do {
            _ = try await conn.sftpListDirectory(path: "/")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await conn.sftpDownloadFile(remotePath: "/etc/hosts")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.sftpUploadFile(data: Data("hi".utf8), remotePath: "/tmp/hi.txt", exclusive: true)
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.sftpUploadFile(data: Data("hi".utf8), remotePath: "/tmp/hi.txt")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await conn.sftpResolvePath(".")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.sftpMakeDirectory(path: "/tmp/newdir")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.sftpDelete(path: "/tmp/file", isDirectory: false)
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await conn.sftpRename(from: "/tmp/a", to: "/tmp/b")
            XCTFail("Expected SFTPError.notConnected")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let rule = PortForwardRule(localPort: 0, remoteHost: "127.0.0.1", remotePort: 8080)
        do {
            _ = try await conn.startLocalForward(rule)
            XCTFail("Expected SSHError.notConnected")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let active = await conn.activePortForwards()
        XCTAssertTrue(active.isEmpty)
        await conn.stopLocalForward(id: rule.id)
        await conn.close()

        do {
            _ = try await conn.sftpListDirectory(path: "/")
            XCTFail("Expected SFTPError.notConnected after close")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await conn.startLocalForward(rule)
            XCTFail("Expected SSHError.notConnected after close")
        } catch let error as SSHError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSFTPUploadFlagsLengthValidationAndHardeningConstants() throws {
        let normalFlags = SFTPUtil.uploadOpenFlags(exclusive: false)
        XCTAssertNotEqual(normalFlags & UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC), 0)
        XCTAssertEqual(normalFlags & UInt(LIBSSH2_FXF_EXCL), 0)

        let exclusiveFlags = SFTPUtil.uploadOpenFlags(exclusive: true)
        XCTAssertEqual(exclusiveFlags & UInt(LIBSSH2_FXF_EXCL), UInt(LIBSSH2_FXF_EXCL))
        XCTAssertEqual(exclusiveFlags & normalFlags, normalFlags)

        XCTAssertEqual(try SFTPUtil.sftpLength(byteCount: 0), 0)
        XCTAssertEqual(try SFTPUtil.sftpLength(byteCount: Int(UInt32.max)), UInt32.max)
        XCTAssertThrowsError(try SFTPUtil.sftpLength(byteCount: -1)) { error in
            guard case SFTPError.ioFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        if MemoryLayout<Int>.size >= 8 {
            XCTAssertThrowsError(try SFTPUtil.sftpLength(byteCount: Int(UInt32.max) + 1)) { error in
                guard case SFTPError.ioFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        XCTAssertEqual(SSHConnection.sftpOperationTimeout, .seconds(30))
        XCTAssertEqual(SSHConnection.maxForwardConcurrentClients, 64)
    }

    func testSFTPUtilHelpers() {
        XCTAssertEqual(SFTPUtil.realpathInput(for: ""), ".")
        XCTAssertEqual(SFTPUtil.realpathInput(for: "."), ".")
        XCTAssertEqual(SFTPUtil.realpathInput(for: "~"), ".")
        XCTAssertEqual(SFTPUtil.realpathInput(for: "~/"), ".")
        XCTAssertEqual(SFTPUtil.realpathInput(for: "~/docs"), "docs")
        XCTAssertEqual(SFTPUtil.realpathInput(for: "/var/log"), "/var/log")

        XCTAssertEqual(SFTPUtil.mapStatus(UInt(LIBSSH2_FX_NO_SUCH_FILE), context: "/x"), .notFound("/x"))
        XCTAssertEqual(SFTPUtil.mapStatus(UInt(LIBSSH2_FX_NO_SUCH_PATH), context: "/x"), .notFound("/x"))
        XCTAssertEqual(SFTPUtil.mapStatus(UInt(LIBSSH2_FX_PERMISSION_DENIED), context: "/x"), .permissionDenied("/x"))
        XCTAssertEqual(SFTPUtil.mapStatus(UInt(LIBSSH2_FX_FAILURE), context: "/x"), .ioFailed("/x (SFTP status 4)"))

        var dirAttrs = LIBSSH2_SFTP_ATTRIBUTES()
        dirAttrs.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_ACMODTIME)
        dirAttrs.permissions = UInt(LIBSSH2_SFTP_S_IFDIR | 0o755)
        dirAttrs.mtime = 1_700_000_000
        let dirEntry = SFTPUtil.makeEntry(directory: "/home/u", name: "sub", attrs: dirAttrs)
        XCTAssertTrue(dirEntry.isDirectory)
        XCTAssertFalse(dirEntry.isSymlink)
        XCTAssertEqual(dirEntry.path, "/home/u/sub")
        XCTAssertEqual(dirEntry.modifiedAt, Date(timeIntervalSince1970: 1_700_000_000))

        var linkAttrs = LIBSSH2_SFTP_ATTRIBUTES()
        linkAttrs.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_SIZE)
        linkAttrs.permissions = UInt(LIBSSH2_SFTP_S_IFLNK | 0o777)
        linkAttrs.filesize = 12
        let linkEntry = SFTPUtil.makeEntry(directory: "/", name: "cur", attrs: linkAttrs)
        XCTAssertFalse(linkEntry.isDirectory)
        XCTAssertTrue(linkEntry.isSymlink)
        XCTAssertEqual(linkEntry.size, 12)
        XCTAssertEqual(linkEntry.path, "/cur")
    }

    func testForwardPipeBufferAndLocalForwardSocket() async throws {
        var buf = ForwardPipeBuffer()
        XCTAssertTrue(buf.isEmpty)
        let payload = Array(repeating: UInt8(0x41), count: 40_000)
        buf.append(payload[...])
        XCTAssertEqual(buf.availableCount, 40_000)
        buf.consume(35_000)
        XCTAssertEqual(buf.availableCount, 5_000)
        XCTAssertEqual(buf.offset, 0)
        buf.consume(5_000)
        XCTAssertTrue(buf.isEmpty)

        let (listenFd, boundPort) = try LocalForwardSocket.bindAndListen(port: 0)
        defer { Darwin.close(listenFd) }
        XCTAssertGreaterThan(boundPort, 0)
        if case .wouldBlock = LocalForwardSocket.acceptNonBlocking(listenFd: listenFd, fallbackPort: boundPort) {
            // Expected when no client has connected yet
        } else {
            XCTFail("Expected .wouldBlock on idle listener")
        }

        var pipeFds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&pipeFds), 0)
        defer { Darwin.close(pipeFds[0]); Darwin.close(pipeFds[1]) }
        let msg = Data("ok".utf8)
        _ = msg.withUnsafeBytes { Darwin.write(pipeFds[1], $0.baseAddress!, msg.count) }
        await SocketPoller.waitAny([(fd: listenFd, interest: .read), (fd: pipeFds[0], interest: .read)], timeoutMs: 500)
        var readBuf = [UInt8](repeating: 0, count: 8)
        let n = Darwin.read(pipeFds[0], &readBuf, readBuf.count)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(Data(readBuf[0..<n]), msg)

        do {
            let clientFd = try await SocketPoller.connect(host: "127.0.0.1", port: boundPort, timeoutMs: 2_000)
            defer { Darwin.close(clientFd) }
            await SocketPoller.waitAny([(fd: listenFd, interest: .read)], timeoutMs: 1_000)
            let accepted = LocalForwardSocket.acceptNonBlocking(listenFd: listenFd, fallbackPort: boundPort)
            guard case .accepted(let serverClientFd, _) = accepted else {
                return XCTFail("Expected accepted connection")
            }
            Darwin.close(serverClientFd)
        } catch let error as SSHError {
            if case .connectionFailed(let msg) = error, msg.contains("Operation not permitted") {
                throw XCTSkip("Sandbox blocked loopback TCP connect: \(msg)")
            }
            throw error
        }
    }
}
