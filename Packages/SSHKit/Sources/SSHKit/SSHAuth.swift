import Foundation

public struct Prompt: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let text: String
        public let echo: Bool
        public init(text: String, echo: Bool) { self.text = text; self.echo = echo }
    }
    public let name: String
    public let instruction: String
    public let items: [Item]
    public init(name: String, instruction: String, items: [Item]) {
        self.name = name; self.instruction = instruction; self.items = items
    }
}

public enum SSHAuth: Sendable {
    case password(String)
    case privateKey(pem: Data, passphrase: String?)
    /// Authenticates with a key whose private half stays elsewhere (e.g. the Secure Enclave).
    /// `publicKeyBlob` is the SSH wire public key blob. `sign` receives the exact bytes to sign and
    /// returns the inner SSH signature blob (for `ecdsa-sha2-nistp256`: `mpint r || mpint s`), or nil on failure.
    /// `sign` runs synchronously on the connection's queue while libssh2 is locked, so it must not wait on UI
    /// (no user-presence or biometric prompt); `close()` cannot interrupt it.
    case signer(publicKeyBlob: Data, sign: @Sendable (Data) -> Data?)
    /// The handler receives one server prompt set and returns one answer per item.
    case keyboardInteractive(handler: @Sendable (Prompt) async -> [String])
}
