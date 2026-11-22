import Foundation
import Security

/// Trusted host-key fingerprints, stored in Keychain (synchronizable or local, chosen by the caller from the app's sync setting).
public struct KnownHostsStore: Sendable {
    public static let defaultService = KeychainService.knownHosts
    private let keychain: KeychainStore
    private let service: String

    public init(keychain: KeychainStore = KeychainStore(), service: String = KnownHostsStore.defaultService) {
        self.keychain = keychain
        self.service = service
    }

    private func account(_ host: String, _ port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func fingerprint(host: String, port: Int) throws -> String? {
        guard let data = try keychain.read(service: service, account: account(host, port)) else { return nil }
        // A corrupt entry must not look like a never-seen host.
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    public func trust(host: String, port: Int, fingerprint: String, synchronizable: Bool = false) throws {
        try keychain.save(Data(fingerprint.utf8), service: service, account: account(host, port), synchronizable: synchronizable)
    }

    public func forget(host: String, port: Int) throws {
        try keychain.delete(service: service, account: account(host, port))
    }
}
