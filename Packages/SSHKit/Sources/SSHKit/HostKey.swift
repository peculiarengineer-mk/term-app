import Foundation
import CLibSSH2

public enum HostKeyType: String, Sendable, Equatable {
    case rsa = "ssh-rsa"
    case dss = "ssh-dss"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case ed25519 = "ssh-ed25519"
    case unknown = "unknown"

    init(libssh2 raw: Int32) {
        switch raw {
        case LIBSSH2_HOSTKEY_TYPE_RSA: self = .rsa
        case LIBSSH2_HOSTKEY_TYPE_DSS: self = .dss
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: self = .ecdsaP256
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: self = .ecdsaP384
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: self = .ecdsaP521
        case LIBSSH2_HOSTKEY_TYPE_ED25519: self = .ed25519
        default: self = .unknown
        }
    }
}

public struct HostKey: Sendable, Equatable {
    public let type: HostKeyType
    /// Raw SHA-256 digest of the host key blob.
    public let sha256: Data
    /// Raw host key blob as sent by the server.
    public let keyData: Data

    public init(type: HostKeyType, sha256: Data, keyData: Data) {
        self.type = type
        self.sha256 = sha256
        self.keyData = keyData
    }

    /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64.
    public var fingerprint: String {
        var b64 = sha256.base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }
}

public enum HostKeyDecision: Sendable {
    case trust
    case reject
}
