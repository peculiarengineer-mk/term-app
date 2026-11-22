import Foundation
import Security

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// Generic-password Keychain items keyed by (service, account).
public struct KeychainStore: Sendable {
    public init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// Writes the item, replacing any existing copy (synchronizable or not).
    /// The new copy is written before the other variant is removed, so a failed write never loses the old secret.
    /// If the final cleanup throws, the new data is already stored; calling `save` again removes the stale copy.
    /// Callers must serialise writes to the same (service, account): concurrent saves with opposite sync values can race.
    public func save(_ data: Data, service: String, account: String, synchronizable: Bool = false) throws {
        let sync: CFBoolean = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // kSecAttrSynchronizableAny is not valid in SecItemAdd; use a concrete value.
            kSecAttrSynchronizable as String: sync,
        ]
        var status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var match = baseQuery(service: service, account: account)
            match[kSecAttrSynchronizable as String] = sync
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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

    private func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
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

    /// Deleting a missing item is not an error.
    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Moves the item to the `synchronizable` flag. Reads the copy with the opposite flag; if none
    /// exists, an existing copy with the target flag means nothing to do, else `errSecItemNotFound`.
    /// If the target copy already exists (a synced copy from another device, or a local one), it is kept
    /// and the old copy stays deleted. Any other add failure restores the old copy before throwing.
    public func setSynchronizable(_ synchronizable: Bool, service: String, account: String) throws {
        guard let data = try read(service: service, account: account, synchronizable: !synchronizable) else {
            if try read(service: service, account: account, synchronizable: synchronizable) != nil { return }
            throw KeychainError(status: errSecItemNotFound)
        }
        var del = baseQuery(service: service, account: account)
        del[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanFalse! : kCFBooleanTrue!
        let delStatus = SecItemDelete(del as CFDictionary)
        guard delStatus == errSecSuccess else { throw KeychainError(status: delStatus) }
        let addStatus = add(data, service: service, account: account, synchronizable: synchronizable)
        if addStatus == errSecSuccess || addStatus == errSecDuplicateItem { return }
        _ = add(data, service: service, account: account, synchronizable: !synchronizable)
        throw KeychainError(status: addStatus)
    }

    private func add(_ data: Data, service: String, account: String, synchronizable: Bool) -> OSStatus {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        return SecItemAdd(attrs as CFDictionary, nil)
    }
}
