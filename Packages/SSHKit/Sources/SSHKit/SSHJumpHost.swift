import Foundation

/// A single bastion/jump SSH hop used to tunnel an `SSHConnection` or `SSHExec` call.
public struct SSHJumpHop: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let auth: SSHAuth
    public let verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        auth: SSHAuth,
        verifyHostKey: @escaping @Sendable (HostKey) async -> HostKeyDecision
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.verifyHostKey = verifyHostKey
    }
}

enum SSHJumpValidator {
    static func validate(_ hops: [SSHJumpHop]) throws {
        for hop in hops {
            let trimmed = hop.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, hop.port > 0 else {
                throw SSHError.connectionFailed("invalid jump host")
            }
        }
    }
}
