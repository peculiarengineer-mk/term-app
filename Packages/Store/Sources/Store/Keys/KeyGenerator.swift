import Foundation
import CryptoKit

public struct GeneratedKey: Sendable {
    public let privateKeyPEM: String
    public let publicLine: String
}

public enum KeyGenerator {
    /// Generates an Ed25519 key. `seed` and `checkInt` are injectable for deterministic output.
    public static func generateEd25519(comment: String, seed: Data? = nil,
                                       checkInt: UInt32 = UInt32.random(in: .min ... .max)) throws -> GeneratedKey {
        let key = try seed.map { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) } ?? Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        return GeneratedKey(
            privateKeyPEM: OpenSSHKeyFormat.ed25519PrivateKey(seed: key.rawRepresentation, publicKey: pub, comment: comment, checkInt: checkInt),
            publicLine: OpenSSHKeyFormat.ed25519PublicLine(publicKey: pub, comment: comment))
    }

    /// Generates and stores a key.
    @discardableResult
    public static func generateAndStore(name: String, comment: String, syncsViaICloud: Bool = false,
                                        store: KeyStore = KeyStore()) throws -> StoredKey {
        let g = try generateEd25519(comment: comment)
        let key = StoredKey(name: name, type: .ed25519, publicKey: g.publicLine, syncsViaICloud: syncsViaICloud)
        try store.add(key, privateKey: Data(g.privateKeyPEM.utf8))
        return key
    }
}
