import Foundation
import Security

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

internal protocol KeychainStoring: Sendable {
    func save(_ data: Data, service: String, account: String, synchronizable: Bool) throws
    func read(service: String, account: String) throws -> Data?
    func read(service: String, account: String, synchronizable: Bool) throws -> Data?
    func readAll(service: String) throws -> [(account: String, data: Data, synchronizable: Bool)]
    func accountExists(service: String, account: String, synchronizable: Bool?) throws -> Bool
    func listAccounts(service: String) throws -> Set<String>
    func delete(service: String, account: String) throws
    func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws
}

/// Generic-password Keychain items keyed by (service, account).
public struct KeychainStore: Sendable, KeychainStoring {
    public init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    private func accessible(synchronizable: Bool) -> CFString {
        synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    private func itemAttributes(_ data: Data, service: String, account: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible(synchronizable: synchronizable),
            // kSecAttrSynchronizableAny is not valid in SecItemAdd; use a concrete value.
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }

    /// Writes the item, replacing any existing copy (synchronizable or not).
    /// The new copy is written before the other variant is removed, so a failed write never loses the old secret.
    /// If the final cleanup throws, the new data is already stored; calling `save` again removes the stale copy.
    /// Callers must serialise writes to the same (service, account): concurrent saves with opposite sync values can race.
    public func save(_ data: Data, service: String, account: String, synchronizable: Bool = false) throws {
        let sync: CFBoolean = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        var status = add(data, service: service, account: account, synchronizable: synchronizable)
        if status == errSecDuplicateItem {
            var match = baseQuery(service: service, account: account)
            match[kSecAttrSynchronizable as String] = sync
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessible(synchronizable: synchronizable),
            ]
            status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        // Sync is part of the item's primary key: drop the copy with the other sync value, if any.
        var other = baseQuery(service: service, account: account)
        let otherSync: CFBoolean = synchronizable ? kCFBooleanFalse : kCFBooleanTrue
        other[kSecAttrSynchronizable as String] = otherSync
        let delStatus = SecItemDelete(other as CFDictionary)
        guard delStatus == errSecSuccess || delStatus == errSecItemNotFound else {
            throw KeychainError(status: delStatus)
        }
    }

    /// Returns the synced copy if both exist (queried by concrete flag, never `Any` + limit one).
    public func read(service: String, account: String) throws -> Data? {
        if let d = try read(service: service, account: account, synchronizable: true) { return d }
        return try read(service: service, account: account, synchronizable: false)
    }

    internal func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        var q = baseQuery(service: service, account: account)
        q[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    /// Every item of `service`, synchronizable or not.
    public func readAll(service: String) throws -> [(account: String, data: Data, synchronizable: Bool)] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { d in
            guard let a = d[kSecAttrAccount as String] as? String, let v = d[kSecValueData as String] as? Data else { return nil }
            let sync = (d[kSecAttrSynchronizable as String] as? Bool) ?? ((d[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false)
            return (a, v, sync)
        }
    }

    /// Checks whether an item exists for `(service, account)` without reading secret bytes into memory.
    public func accountExists(service: String, account: String, synchronizable: Bool? = nil) throws -> Bool {
        var q = baseQuery(service: service, account: account)
        if let synchronizable {
            q[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        }
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result != nil
    }

    /// Lists all account identifiers under `service` without reading secret bytes into memory.
    public func listAccounts(service: String) throws -> Set<String> {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    /// Deleting a missing item is not an error.
    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Moves the item to the `synchronizable` flag. Reads the copy with the opposite flag; if none
    /// exists, an existing copy with the target flag means nothing to do, else `errSecItemNotFound`.
    /// Adds the target copy first (treating `errSecDuplicateItem` as keeping the existing target copy)
    /// and deletes the old copy only once the target copy exists, so a failed add never loses the secret.
    public func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws {
        guard let data = try read(service: service, account: account, synchronizable: !synchronizable) else {
            if try read(service: service, account: account, synchronizable: synchronizable) != nil { return }
            throw KeychainError(status: errSecItemNotFound)
        }
        let addStatus = add(data, service: service, account: account, synchronizable: synchronizable)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw KeychainError(status: addStatus)
        }
        var del = baseQuery(service: service, account: account)
        del[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanFalse! : kCFBooleanTrue!
        let delStatus = SecItemDelete(del as CFDictionary)
        guard delStatus == errSecSuccess || delStatus == errSecItemNotFound else {
            throw KeychainError(status: delStatus)
        }
    }

    private func add(_ data: Data, service: String, account: String, synchronizable: Bool) -> OSStatus {
        SecItemAdd(itemAttributes(data, service: service, account: account, synchronizable: synchronizable) as CFDictionary, nil)
    }
}
