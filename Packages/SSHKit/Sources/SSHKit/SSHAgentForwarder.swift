import Foundation

/// Signature request flags defined by the OpenSSH agent protocol (`draft-miller-ssh-agent`).
public enum SSHAgentFlags {
    public static let rsaSHA2_256: UInt32 = 0x02
    public static let rsaSHA2_512: UInt32 = 0x04
}

/// An identity exposed to remote processes when SSH agent forwarding (`-A`) is enabled.
public struct SSHAgentIdentity: Sendable {
    public let publicKeyBlob: Data
    public let comment: String
    /// Signs `data` and returns the inner SSH signature blob (matching `SSHAuth.signer`:
    /// e.g. `mpint r || mpint s` for `ecdsa-sha2-nistp256` or 64-byte raw signature for `ssh-ed25519`),
    /// or `nil` on failure.
    public let sign: @Sendable (Data) -> Data?
    private let signWithFlagsHandler: (@Sendable (Data, UInt32) throws -> Data)?

    /// Creates an identity whose signing closure matches `SSHAuth.signer`.
    public init(
        publicKeyBlob: Data,
        comment: String = "",
        sign: @escaping @Sendable (Data) -> Data?
    ) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
        self.sign = sign
        self.signWithFlagsHandler = nil
    }

    /// Creates an identity whose signing closure receives the OpenSSH `SSH_AGENTC_SIGN_REQUEST` flags
    /// (for example `SSHAgentFlags.rsaSHA2_256` / `SSHAgentFlags.rsaSHA2_512` on `"ssh-rsa"` keys)
    /// and returns the inner SSH signature blob.
    public init(
        publicKeyBlob: Data,
        comment: String = "",
        signWithFlags: @escaping @Sendable (Data, UInt32) throws -> Data
    ) {
        self.publicKeyBlob = publicKeyBlob
        self.comment = comment
        self.sign = { data in try? signWithFlags(data, 0) }
        self.signWithFlagsHandler = signWithFlags
    }

    func performSign(data: Data, flags: UInt32, keyType: String) -> Data? {
        if let signWithFlagsHandler {
            guard let sig = try? signWithFlagsHandler(data, flags), !sig.isEmpty else { return nil }
            return sig
        }
        // A flagless signer cannot switch RSA digest algorithms when SHA-2 flags are requested.
        if keyType == "ssh-rsa", (flags & (SSHAgentFlags.rsaSHA2_256 | SSHAgentFlags.rsaSHA2_512)) != 0 {
            return nil
        }
        guard let sig = sign(data), !sig.isEmpty else { return nil }
        return sig
    }
}

/// Configuration for SSH agent forwarding (`auth-agent@openssh.com`) on an `SSHConnection`.
public struct SSHAgentForwardingConfig: Sendable {
    public let identities: [SSHAgentIdentity]

    public init(identities: [SSHAgentIdentity]) {
        self.identities = identities
    }
}

/// OpenSSH agent protocol message types and wire-framing codec.
enum SSHAgentProtocol {
    static let failure: UInt8 = 5
    static let success: UInt8 = 6
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14

    /// Caps an incoming agent message payload to 256 KiB (matching OpenSSH's `AGENT_MAX_LEN`).
    static let maxPacketBytes = 256 * 1024

    enum ExtractedPacket: Equatable {
        case payload(Data)
        case invalidFraming
    }

    /// Attempts to extract one length-prefixed OpenSSH agent message from `buffer`.
    static func extractPacket(from buffer: inout ForwardPipeBuffer) -> ExtractedPacket? {
        guard buffer.availableCount >= 4 else { return nil }
        let length: UInt32 = buffer.withReadableBytes { ptr, _ in
            (UInt32(ptr[0]) << 24)
                | (UInt32(ptr[1]) << 16)
                | (UInt32(ptr[2]) << 8)
                | UInt32(ptr[3])
        }
        guard length >= 1, Int(length) <= maxPacketBytes else {
            return .invalidFraming
        }
        let frameSize = 4 + Int(length)
        guard buffer.availableCount >= frameSize else { return nil }
        let payload = buffer.withReadableBytes { ptr, _ in
            Data(bytes: ptr + 4, count: Int(length))
        }
        buffer.consume(frameSize)
        return .payload(payload)
    }

    /// Wraps a raw agent message payload with its 4-byte big-endian length prefix.
    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        appendUInt32(UInt32(payload.count), to: &out)
        out.append(payload)
        return out
    }

    static func failurePayload() -> Data {
        Data([failure])
    }

    /// Processes a single OpenSSH agent request payload and returns the unframed response payload.
    static func processRequest(_ payload: Data, identities: [SSHAgentIdentity]) -> Data {
        var reader = WireReader(payload)
        guard let messageType = reader.readByte() else {
            return failurePayload()
        }
        switch messageType {
        case requestIdentities:
            guard reader.remaining == 0 else { return failurePayload() }
            return buildIdentitiesAnswer(identities)

        case signRequest:
            guard let keyBlob = reader.readString(),
                  let dataToSign = reader.readString(),
                  let flags = reader.readUInt32(),
                  reader.remaining == 0 else {
                return failurePayload()
            }
            return handleSignRequest(
                keyBlob: keyBlob,
                data: dataToSign,
                flags: flags,
                identities: identities
            )

        default:
            return failurePayload()
        }
    }

    static func buildIdentitiesAnswer(_ identities: [SSHAgentIdentity]) -> Data {
        var out = Data()
        out.append(identitiesAnswer)
        appendUInt32(UInt32(identities.count), to: &out)
        for identity in identities {
            appendString(identity.publicKeyBlob, to: &out)
            appendString(Data(identity.comment.utf8), to: &out)
        }
        return out
    }

    static func handleSignRequest(
        keyBlob: Data,
        data: Data,
        flags: UInt32,
        identities: [SSHAgentIdentity]
    ) -> Data {
        guard let identity = identities.first(where: { $0.publicKeyBlob == keyBlob }),
              let keyType = publicKeyAlgorithm(from: keyBlob),
              let sigAlgorithm = signatureAlgorithm(forKeyType: keyType, flags: flags),
              let innerSig = identity.performSign(data: data, flags: flags, keyType: keyType) else {
            return failurePayload()
        }

        var wireSignature = Data()
        appendString(Data(sigAlgorithm.utf8), to: &wireSignature)
        appendString(innerSig, to: &wireSignature)

        var out = Data()
        out.append(signResponse)
        appendString(wireSignature, to: &out)
        return out
    }

    static func publicKeyAlgorithm(from keyBlob: Data) -> String? {
        var reader = WireReader(keyBlob)
        guard let algBytes = reader.readString(), !algBytes.isEmpty else { return nil }
        let alg = String(decoding: algBytes, as: UTF8.self)
        return alg.isEmpty ? nil : alg
    }

    static func signatureAlgorithm(forKeyType keyType: String, flags: UInt32) -> String? {
        let rsaSHA2Mask = SSHAgentFlags.rsaSHA2_256 | SSHAgentFlags.rsaSHA2_512
        if keyType == "ssh-rsa" {
            if (flags & ~rsaSHA2Mask) != 0 { return nil }
            if (flags & SSHAgentFlags.rsaSHA2_512) != 0 { return "rsa-sha2-512" }
            if (flags & SSHAgentFlags.rsaSHA2_256) != 0 { return "rsa-sha2-256" }
            return "ssh-rsa"
        }
        guard flags == 0 else { return nil }
        return keyType
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    static func appendString(_ bytes: Data, to data: inout Data) {
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    struct WireReader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) {
            self.data = data
        }

        var remaining: Int { data.count - offset }

        mutating func readByte() -> UInt8? {
            guard offset < data.count else { return nil }
            let idx = data.index(data.startIndex, offsetBy: offset)
            offset += 1
            return data[idx]
        }

        mutating func readUInt32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: 4)
            offset += 4
            var value: UInt32 = 0
            for b in data[start..<end] {
                value = (value << 8) | UInt32(b)
            }
            return value
        }

        mutating func readString() -> Data? {
            guard let len = readUInt32() else { return nil }
            let count = Int(len)
            guard count <= remaining else { return nil }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            offset += count
            return Data(data[start..<end])
        }
    }
}
