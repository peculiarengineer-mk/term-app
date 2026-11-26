import XCTest
import Foundation
import CryptoKit
import CLibSSH2
@testable import SSHKit

final class SSHAgentForwarderTests: XCTestCase {
    private static func sshString(_ bytes: Data) -> Data {
        var out = Data()
        SSHAgentProtocol.appendString(bytes, to: &out)
        return out
    }

    private static func mpint(_ raw: Data) -> Data {
        var trimmed = Data(raw.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 {
            trimmed.insert(0, at: 0)
        }
        return sshString(trimmed)
    }

    private static func ed25519Blob(_ key: Curve25519.Signing.PrivateKey) -> Data {
        sshString(Data("ssh-ed25519".utf8)) + sshString(key.publicKey.rawRepresentation)
    }

    private static func p256Blob(_ key: P256.Signing.PrivateKey) -> Data {
        sshString(Data("ecdsa-sha2-nistp256".utf8))
            + sshString(Data("nistp256".utf8))
            + sshString(key.publicKey.x963Representation)
    }

    private static func rsaBlob() -> Data {
        sshString(Data("ssh-rsa".utf8))
            + sshString(Data([0x01, 0x00, 0x01]))
            + sshString(Data(repeating: 0xAB, count: 32))
    }

    private static func makeSignRequest(keyBlob: Data, data: Data, flags: UInt32 = 0) -> Data {
        var payload = Data([SSHAgentProtocol.signRequest])
        SSHAgentProtocol.appendString(keyBlob, to: &payload)
        SSHAgentProtocol.appendString(data, to: &payload)
        SSHAgentProtocol.appendUInt32(flags, to: &payload)
        return payload
    }

    func testRequestIdentitiesEmptyAndMultiple() throws {
        let emptyResp = SSHAgentProtocol.processRequest(Data([SSHAgentProtocol.requestIdentities]), identities: [])
        var emptyReader = SSHAgentProtocol.WireReader(emptyResp)
        XCTAssertEqual(emptyReader.readByte(), SSHAgentProtocol.identitiesAnswer)
        XCTAssertEqual(emptyReader.readUInt32(), 0)
        XCTAssertEqual(emptyReader.remaining, 0)

        let edKey = Curve25519.Signing.PrivateKey()
        let p256Key = P256.Signing.PrivateKey()
        let id1 = SSHAgentIdentity(publicKeyBlob: Self.ed25519Blob(edKey), comment: "ed-key") { _ in nil }
        let id2 = SSHAgentIdentity(publicKeyBlob: Self.p256Blob(p256Key), comment: "se-p256-🔑") { _ in nil }

        let resp = SSHAgentProtocol.processRequest(Data([SSHAgentProtocol.requestIdentities]), identities: [id1, id2])
        var reader = SSHAgentProtocol.WireReader(resp)
        XCTAssertEqual(reader.readByte(), SSHAgentProtocol.identitiesAnswer)
        XCTAssertEqual(reader.readUInt32(), 2)
        XCTAssertEqual(reader.readString(), id1.publicKeyBlob)
        XCTAssertEqual(reader.readString().map { String(decoding: $0, as: UTF8.self) }, "ed-key")
        XCTAssertEqual(reader.readString(), id2.publicKeyBlob)
        XCTAssertEqual(reader.readString().map { String(decoding: $0, as: UTF8.self) }, "se-p256-🔑")
        XCTAssertEqual(reader.remaining, 0)
    }

    func testSignRequestEd25519ProducesVerifiableWireSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let blob = Self.ed25519Blob(key)
        let identity = SSHAgentIdentity(publicKeyBlob: blob, comment: "ed") { msg in
            try? key.signature(for: msg)
        }

        let challenge = Data("ssh-userauth-challenge-ed25519".utf8)
        let req = Self.makeSignRequest(keyBlob: blob, data: challenge)
        let resp = SSHAgentProtocol.processRequest(req, identities: [identity])

        var respReader = SSHAgentProtocol.WireReader(resp)
        XCTAssertEqual(respReader.readByte(), SSHAgentProtocol.signResponse)
        let wireSig = try XCTUnwrap(respReader.readString())
        XCTAssertEqual(respReader.remaining, 0)

        var sigReader = SSHAgentProtocol.WireReader(wireSig)
        let alg = try XCTUnwrap(sigReader.readString())
        let inner = try XCTUnwrap(sigReader.readString())
        XCTAssertEqual(sigReader.remaining, 0)
        XCTAssertEqual(String(decoding: alg, as: UTF8.self), "ssh-ed25519")
        XCTAssertEqual(inner.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(inner, for: challenge))
    }

    func testSignRequestECDSAP256MatchesSSHAuthSignerContract() throws {
        let key = P256.Signing.PrivateKey()
        let blob = Self.p256Blob(key)
        // Matches SSHAuth.signer / SecureEnclaveKey.signer: returns inner mpint(r) || mpint(s).
        let identity = SSHAgentIdentity(publicKeyBlob: blob, comment: "p256") { msg in
            guard let sig = try? key.signature(for: msg) else { return nil }
            let raw = sig.rawRepresentation
            return Self.mpint(raw.prefix(32)) + Self.mpint(raw.suffix(32))
        }

        let challenge = Data("ssh-userauth-challenge-p256".utf8)
        let req = Self.makeSignRequest(keyBlob: blob, data: challenge)
        let resp = SSHAgentProtocol.processRequest(req, identities: [identity])

        var respReader = SSHAgentProtocol.WireReader(resp)
        XCTAssertEqual(respReader.readByte(), SSHAgentProtocol.signResponse)
        let wireSig = try XCTUnwrap(respReader.readString())
        XCTAssertEqual(respReader.remaining, 0)

        var sigReader = SSHAgentProtocol.WireReader(wireSig)
        let alg = try XCTUnwrap(sigReader.readString())
        let inner = try XCTUnwrap(sigReader.readString())
        XCTAssertEqual(sigReader.remaining, 0)
        XCTAssertEqual(String(decoding: alg, as: UTF8.self), "ecdsa-sha2-nistp256")

        var innerReader = SSHAgentProtocol.WireReader(inner)
        let rBytes = try XCTUnwrap(innerReader.readString())
        let sBytes = try XCTUnwrap(innerReader.readString())
        XCTAssertEqual(innerReader.remaining, 0)

        func fixed32(_ mpint: Data) -> Data {
            var bytes = Array(mpint)
            if bytes.first == 0 { bytes.removeFirst() }
            if bytes.count < 32 {
                bytes = [UInt8](repeating: 0, count: 32 - bytes.count) + bytes
            }
            return Data(bytes)
        }
        let cryptoSig = try P256.Signing.ECDSASignature(rawRepresentation: fixed32(rBytes) + fixed32(sBytes))
        XCTAssertTrue(key.publicKey.isValidSignature(cryptoSig, for: challenge))
    }

    func testSignRequestRSAFlagsRespectSHA2Algorithms() throws {
        let rsaKeyBlob = Self.rsaBlob()
        let recordedFlags = NSLockBox<UInt32>()

        let flagsIdentity = SSHAgentIdentity(publicKeyBlob: rsaKeyBlob, comment: "rsa") { data, flags in
            recordedFlags.set(flags)
            return Data("sig-\(flags)-\(data.count)".utf8)
        }

        let challenge = Data("rsa-payload".utf8)
        for (flags, expectedAlg) in [
            (UInt32(0), "ssh-rsa"),
            (SSHAgentFlags.rsaSHA2_256, "rsa-sha2-256"),
            (SSHAgentFlags.rsaSHA2_512, "rsa-sha2-512"),
        ] {
            let resp = SSHAgentProtocol.processRequest(
                Self.makeSignRequest(keyBlob: rsaKeyBlob, data: challenge, flags: flags),
                identities: [flagsIdentity]
            )
            XCTAssertEqual(recordedFlags.get(), flags)
            var reader = SSHAgentProtocol.WireReader(resp)
            XCTAssertEqual(reader.readByte(), SSHAgentProtocol.signResponse)
            let wireSig = try XCTUnwrap(reader.readString())
            var sigReader = SSHAgentProtocol.WireReader(wireSig)
            let alg = try XCTUnwrap(sigReader.readString())
            XCTAssertEqual(String(decoding: alg, as: UTF8.self), expectedAlg)
        }

        // Flagless signer refuses RSA SHA-2 flag requests instead of mislabeling a SHA-1 signature.
        let flaglessRSA = SSHAgentIdentity(publicKeyBlob: rsaKeyBlob, comment: "rsa-flagless") { _ in
            Data([0x01, 0x02])
        }
        let rejected = SSHAgentProtocol.processRequest(
            Self.makeSignRequest(keyBlob: rsaKeyBlob, data: challenge, flags: SSHAgentFlags.rsaSHA2_256),
            identities: [flaglessRSA]
        )
        XCTAssertEqual(rejected, Data([SSHAgentProtocol.failure]))
    }

    func testSignRequestFailureCases() {
        let key = Curve25519.Signing.PrivateKey()
        let blob = Self.ed25519Blob(key)
        let nilSigner = SSHAgentIdentity(publicKeyBlob: blob, comment: "nil") { _ in nil }
        let okSigner = SSHAgentIdentity(publicKeyBlob: blob, comment: "ok") { _ in Data(repeating: 1, count: 64) }
        let throwingSigner = SSHAgentIdentity(publicKeyBlob: blob, comment: "throw") { _, _ in
            throw SSHError.channelFailed("locked")
        }

        // Unknown key blob
        let unknownBlob = Self.ed25519Blob(Curve25519.Signing.PrivateKey())
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Self.makeSignRequest(keyBlob: unknownBlob, data: Data("a".utf8)), identities: [okSigner]),
            Data([SSHAgentProtocol.failure])
        )
        // Signer returns nil
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Self.makeSignRequest(keyBlob: blob, data: Data("a".utf8)), identities: [nilSigner]),
            Data([SSHAgentProtocol.failure])
        )
        // Signer throws
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Self.makeSignRequest(keyBlob: blob, data: Data("a".utf8)), identities: [throwingSigner]),
            Data([SSHAgentProtocol.failure])
        )
        // Invalid flags for non-RSA key
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(
                Self.makeSignRequest(keyBlob: blob, data: Data("a".utf8), flags: SSHAgentFlags.rsaSHA2_256),
                identities: [okSigner]
            ),
            Data([SSHAgentProtocol.failure])
        )
        // Unsupported extension / unknown opcode
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Data([27, 0, 0, 0, 1, 65]), identities: [okSigner]),
            Data([SSHAgentProtocol.failure])
        )
        // Truncated sign request and trailing garbage on identities request
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Data([SSHAgentProtocol.signRequest, 0, 0]), identities: [okSigner]),
            Data([SSHAgentProtocol.failure])
        )
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Data([SSHAgentProtocol.requestIdentities, 0xFF]), identities: [okSigner]),
            Data([SSHAgentProtocol.failure])
        )
        XCTAssertEqual(
            SSHAgentProtocol.processRequest(Data(), identities: [okSigner]),
            Data([SSHAgentProtocol.failure])
        )
    }

    func testWireFramingHandlesSplitChunksCoalescedPacketsAndOversizedLength() {
        var buffer = ForwardPipeBuffer()
        let p1 = SSHAgentProtocol.frame(Data([SSHAgentProtocol.requestIdentities]))
        let p2 = SSHAgentProtocol.frame(Data([SSHAgentProtocol.failure]))
        let combined = Array(p1 + p2)

        // Feed 1 byte at a time until p1 completes, then feed the remainder.
        for i in 0..<(p1.count - 1) {
            buffer.append(combined[i..<(i + 1)])
            XCTAssertNil(SSHAgentProtocol.extractPacket(from: &buffer))
        }
        buffer.append(combined[(p1.count - 1)...])

        XCTAssertEqual(SSHAgentProtocol.extractPacket(from: &buffer), .payload(Data([SSHAgentProtocol.requestIdentities])))
        XCTAssertEqual(SSHAgentProtocol.extractPacket(from: &buffer), .payload(Data([SSHAgentProtocol.failure])))
        XCTAssertNil(SSHAgentProtocol.extractPacket(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)

        // Reject oversized length (> 256 KiB) and zero length without consuming bogus sizes.
        var tooLarge = Data()
        SSHAgentProtocol.appendUInt32(UInt32(SSHAgentProtocol.maxPacketBytes + 1), to: &tooLarge)
        buffer.append(Array(tooLarge)[...])
        XCTAssertEqual(SSHAgentProtocol.extractPacket(from: &buffer), .invalidFraming)

        var zeroLenBuffer = ForwardPipeBuffer()
        zeroLenBuffer.append([0, 0, 0, 0][...])
        XCTAssertEqual(SSHAgentProtocol.extractPacket(from: &zeroLenBuffer), .invalidFraming)
    }

    func testSessionAbstractHandleRetainsAndReleasesWithoutRetainCycle() {
        weak var weakContext: CallbackContext?
        let handle = SessionAbstractHandle()
        autoreleasepool {
            let ctx = CallbackContext()
            weakContext = ctx
            ctx.enableAgentForwarding()
            let ptr = handle.retain(ctx)
            XCTAssertTrue(Unmanaged<CallbackContext>.fromOpaque(ptr).takeUnretainedValue().isAgentForwardingEnabled)
            XCTAssertNotNil(weakContext)
        }
        // Retained by SessionAbstractHandle even after local scope ends.
        XCTAssertNotNil(weakContext)
        handle.release()
        XCTAssertNil(weakContext)
    }

    func testCallbackContextAgentChannelQueue() {
        let ctx = CallbackContext()
        XCTAssertFalse(ctx.isAgentForwardingEnabled)
        XCTAssertFalse(ctx.hasPendingAgentChannels)

        ctx.enableAgentForwarding()
        XCTAssertTrue(ctx.isAgentForwardingEnabled)

        let dummyPtr = OpaquePointer(bitPattern: 0x1234)!
        ctx.enqueueAgentChannel(dummyPtr)
        XCTAssertTrue(ctx.hasPendingAgentChannels)

        let drained = ctx.drainPendingAgentChannels()
        XCTAssertEqual(drained.map(\.pointer), [dummyPtr])
        XCTAssertFalse(ctx.hasPendingAgentChannels)

        ctx.disableAgentForwarding()
        XCTAssertFalse(ctx.isAgentForwardingEnabled)
    }

    func testSSHConnectionWithAgentForwardingClosesCleanlyBeforeConnect() async {
        let key = Curve25519.Signing.PrivateKey()
        let id = SSHAgentIdentity(publicKeyBlob: Self.ed25519Blob(key), comment: "test") { msg in
            try? key.signature(for: msg)
        }
        let config = SSHAgentForwardingConfig(identities: [id])
        let conn = SSHConnection(
            host: "127.0.0.1",
            username: "u",
            auth: .password("p"),
            agentForwarding: config
        )
        let activeCount = await conn.activeAgentChannelCountForTesting
        XCTAssertEqual(activeCount, 0)
        await conn.close()

        var states: [SessionState] = []
        for await s in conn.state {
            states.append(s)
        }
        XCTAssertEqual(states, [.disconnected(nil)])
    }
}

private final class NSLockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
