import Foundation

public enum KeyImporter {
    /// Classifies key text without storing it.
    public static func inspect(_ text: String) throws -> ParsedKey { try OpenSSHKeyFormat.parse(text) }

    /// Stores the key text as-is (encrypted keys stay encrypted; libssh2 decrypts at auth time).
    /// `savePassphrase` is only kept when the key is encrypted.
    @discardableResult
    public static func importKey(name: String, text: String, passphrase: String? = nil, savePassphrase: Bool = false,
                                 syncsViaICloud: Bool = false, store: KeyStore = KeyStore()) throws -> StoredKey {
        let parsed = try inspect(text)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let key = StoredKey(name: name, type: parsed.type, publicKey: parsed.publicKeyLine ?? "",
                            isEncrypted: parsed.isEncrypted, syncsViaICloud: syncsViaICloud)
        let keep = (parsed.isEncrypted && savePassphrase) ? passphrase : nil
        try store.add(key, privateKey: Data(normalized.utf8), passphrase: keep)
        return key
    }
}
