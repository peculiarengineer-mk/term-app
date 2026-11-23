import Foundation

public enum KeyType: String, Codable, Sendable, CaseIterable {
    case ed25519, ecdsa, rsa
    case secureEnclaveP256
}

public enum KeyStoreError: Error, Equatable, Sendable {
    case secureEnclaveKeyCannotSync
    case secureEnclaveUnavailable
    case keyMissing
}

/// Key metadata. The private key bytes live in Keychain under `KeyStore.privateService`, never here.
public struct StoredKey: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: KeyType
    /// `ssh-ed25519 AAAA… comment`; empty when it cannot be derived (passphrase-protected PEM).
    public var publicKey: String
    public var isEncrypted: Bool
    public var syncsViaICloud: Bool

    public init(id: UUID = UUID(), name: String, type: KeyType, publicKey: String,
                isEncrypted: Bool = false, syncsViaICloud: Bool = false) {
        self.id = id; self.name = name; self.type = type; self.publicKey = publicKey
        self.isEncrypted = isEncrypted; self.syncsViaICloud = syncsViaICloud
    }
}

/// Keychain-backed key storage: private key, optional passphrase, and one metadata item per key.
/// All three items of a key carry the same sync flag and are flipped together, so a synced key is
/// listed on every device. Callers must serialise mutations.
public struct KeyStore: Sendable {
    public static let privateService = "app.termapp.key.private"
    public static let passphraseService = "app.termapp.key.passphrase"
    public static let metaService = "app.termapp.key.meta"

    private let keychain: any KeychainStoring
    public init(keychain: KeychainStore = KeychainStore()) { self.keychain = keychain }
    internal init(storage: any KeychainStoring) { self.keychain = storage }

    public func list() throws -> [StoredKey] {
        let decoder = JSONDecoder()
        // A synced and a local copy of the same key can briefly coexist; list each key once,
        // preferring the copy whose recorded flag is "synced" (the one other devices see).
        var byID: [UUID: StoredKey] = [:]
        for item in try keychain.readAll(service: Self.metaService) {
            guard let k = try? decoder.decode(StoredKey.self, from: item.data) else { continue }
            if let existing = byID[k.id], existing.syncsViaICloud, !k.syncsViaICloud { continue }
            byID[k.id] = k
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func add(_ key: StoredKey, privateKey: Data, passphrase: String? = nil) throws {
        var key = key
        // Enclave-wrapped blobs only work on this device; never sync them.
        if key.type == .secureEnclaveP256 { key.syncsViaICloud = false }
        let acct = key.id.uuidString
        let sync = key.syncsViaICloud
        try keychain.save(privateKey, service: Self.privateService, account: acct, synchronizable: sync)
        do {
            if let passphrase {
                try keychain.save(Data(passphrase.utf8), service: Self.passphraseService, account: acct, synchronizable: sync)
            }
            try keychain.save(JSONEncoder().encode(key), service: Self.metaService, account: acct, synchronizable: sync)
        } catch {
            try? keychain.delete(service: Self.privateService, account: acct)
            try? keychain.delete(service: Self.passphraseService, account: acct)
            try? keychain.delete(service: Self.metaService, account: acct)
            throw error
        }
    }

    public func privateKey(for key: StoredKey) throws -> Data? {
        try keychain.read(service: Self.privateService, account: key.id.uuidString)
    }

    public func passphrase(for key: StoredKey) throws -> String? {
        try keychain.read(service: Self.passphraseService, account: key.id.uuidString)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Saves a typed passphrase carrying the key's own sync flag (read from stored metadata).
    public func savePassphrase(_ passphrase: String, for key: StoredKey) throws {
        let acct = key.id.uuidString
        let stored = (try keychain.read(service: Self.metaService, account: acct))
            .flatMap { try? JSONDecoder().decode(StoredKey.self, from: $0) } ?? key
        try keychain.save(Data(passphrase.utf8), service: Self.passphraseService, account: acct,
                          synchronizable: stored.syncsViaICloud)
    }

    public func setSynchronizable(_ on: Bool, for key: StoredKey) throws {
        if key.type == .secureEnclaveP256 {
            if on { throw KeyStoreError.secureEnclaveKeyCannotSync }
            return
        }
        let acct = key.id.uuidString
        // Fail closed when metadata is missing or unreadable, and verify the stored type too.
        guard let meta = try keychain.read(service: Self.metaService, account: acct) else {
            throw KeyStoreError.keyMissing
        }
        let storedMeta = try JSONDecoder().decode(StoredKey.self, from: meta)
        if storedMeta.type == .secureEnclaveP256 {
            if on { throw KeyStoreError.secureEnclaveKeyCannotSync }
            return
        }
        let hadOppositePrivate = try keychain.read(service: Self.privateService, account: acct, synchronizable: !on) != nil
        let hadTargetPrivate = try keychain.read(service: Self.privateService, account: acct, synchronizable: on) != nil
        try keychain.setSynchronizable(on, service: Self.privateService, account: acct)
        let flippedPrivate = hadOppositePrivate && !hadTargetPrivate
        var flippedPassphrase = false
        do {
            let hadOppositePassphrase = try keychain.read(service: Self.passphraseService, account: acct, synchronizable: !on) != nil
            let hadTargetPassphrase = try keychain.read(service: Self.passphraseService, account: acct, synchronizable: on) != nil
            if hadOppositePassphrase || hadTargetPassphrase {
                try keychain.setSynchronizable(on, service: Self.passphraseService, account: acct)
                flippedPassphrase = hadOppositePassphrase && !hadTargetPassphrase
            }
            var updated = storedMeta
            updated.syncsViaICloud = on
            try keychain.save(JSONEncoder().encode(updated), service: Self.metaService, account: acct, synchronizable: on)
        } catch {
            if flippedPassphrase {
                try? keychain.setSynchronizable(!on, service: Self.passphraseService, account: acct)
            }
            if flippedPrivate {
                try? keychain.setSynchronizable(!on, service: Self.privateService, account: acct)
            }
            throw error
        }
    }

    public func delete(_ key: StoredKey) throws {
        let acct = key.id.uuidString
        try keychain.delete(service: Self.privateService, account: acct)
        try keychain.delete(service: Self.passphraseService, account: acct)
        try keychain.delete(service: Self.metaService, account: acct)
    }
}
