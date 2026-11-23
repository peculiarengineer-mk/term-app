import Foundation
import CryptoKit
import Security

/// Secure Enclave P-256 login keys. The Keychain holds only the enclave-wrapped `dataRepresentation`,
/// which this device's enclave alone can use; it is never synchronised.
public enum SecureEnclaveKey {
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public static func generateAndStore(name: String, comment: String, store: KeyStore) throws -> StoredKey {
        guard isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else {
            throw error!.takeRetainedValue()
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let point = key.publicKey.x963Representation
        let stored = StoredKey(name: name, type: .secureEnclaveP256,
                               publicKey: SSHECDSA.publicLine(x963: point, comment: comment),
                               isEncrypted: false, syncsViaICloud: false)
        try store.add(stored, privateKey: key.dataRepresentation)
        return stored
    }

    public static func signer(for key: StoredKey, store: KeyStore) throws
        -> (publicKeyBlob: Data, sign: @Sendable (Data) -> Data?) {
        guard isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
        guard let representation = try store.privateKey(for: key) else {
            throw KeyStoreError.keyMissing
        }
        let priv = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
        let blob = SSHECDSA.publicKeyBlob(x963: priv.publicKey.x963Representation)
        // Reload per call from the value-typed representation so the closure captures only Sendable Data.
        let sign: @Sendable (Data) -> Data? = { message in
            guard let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation),
                  let sig = try? k.signature(for: message) else { return nil }
            return SSHECDSA.signatureBlob(rawRS: sig.rawRepresentation)
        }
        return (blob, sign)
    }
}
