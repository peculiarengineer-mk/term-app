import Foundation
import CLibSSH2

/// The client's explicit algorithm offer, as comma-separated SSH wire names in preference order.
/// libssh2 itself prepends `ext-info-c,kex-strict-c-v00@openssh.com` to the kex list.
public enum AlgorithmPolicy {
    public static let kex = "mlkem768x25519-sha256,mlkem768nistp256-sha256,mlkem1024nistp384-sha384,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
    public static let ciphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
    public static let macs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
    public static let hostKeys = "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256"

    public static let postQuantumKex: Set<String> = [
        "mlkem768x25519-sha256", "mlkem768nistp256-sha256", "mlkem1024nistp384-sha384",
        "sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com",
    ]
}

/// What the handshake actually agreed on (client-to-server direction for cipher and MAC).
public struct NegotiatedAlgorithms: Sendable, Equatable {
    public let kex: String
    public let hostKey: String
    public let cipher: String
    /// For AEAD ciphers this is not a real MAC: libssh2 reports a placeholder for AES-GCM and an unused
    /// negotiated HMAC for chacha20-poly1305. Show it only for non-AEAD ciphers.
    public let mac: String

    public init(kex: String, hostKey: String, cipher: String, mac: String) {
        self.kex = kex; self.hostKey = hostKey; self.cipher = cipher; self.mac = mac
    }

    public var isPostQuantum: Bool { AlgorithmPolicy.postQuantumKex.contains(kex) }
}

extension AlgorithmPolicy {
    /// libssh2 method types paired with the policy list offered for them.
    static let methodLists: [(method: Int32, name: String, list: String)] = [
        (LIBSSH2_METHOD_KEX, "kex", kex),
        (LIBSSH2_METHOD_HOSTKEY, "hostkey", hostKeys),
        (LIBSSH2_METHOD_CRYPT_CS, "cipher client-to-server", ciphers),
        (LIBSSH2_METHOD_CRYPT_SC, "cipher server-to-client", ciphers),
        (LIBSSH2_METHOD_MAC_CS, "mac client-to-server", macs),
        (LIBSSH2_METHOD_MAC_SC, "mac server-to-client", macs),
    ]

    /// Policy names the linked libssh2 does not implement. `libssh2_session_method_pref` silently drops
    /// unknown names, so this is how a rebuild that lost e.g. ML-KEM is caught instead of quietly downgrading.
    static func unsupportedNames(session s: OpaquePointer) -> [String] {
        var missing: [String] = []
        for entry in methodLists {
            var algs: UnsafeMutablePointer<UnsafePointer<CChar>?>?
            let n = libssh2_session_supported_algs(s, entry.method, &algs)
            if n < 0 { missing.append("\(entry.name): supported_algs failed (\(n))"); continue }
            var have = Set<String>()
            if n > 0, let algs {
                for i in 0..<Int(n) { if let p = algs[i] { have.insert(String(cString: p)) } }
                libssh2_free(s, algs)
            }
            for name in entry.list.split(separator: ",").map(String.init) where !have.contains(name) {
                missing.append("\(entry.name): \(name)")
            }
        }
        return missing
    }

    /// Same check on a throwaway session (used by tests).
    static func unsupportedNames() -> [String] {
        guard LibSSH2Runtime.ensureInitialized() else { return ["libssh2_init failed"] }
        guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else { return ["session init failed"] }
        defer { libssh2_session_free(s) }
        return unsupportedNames(session: s)
    }
}

/// Thread-safe one-time initialization of libssh2 global state (must run before `libssh2_session_init_ex`).
enum LibSSH2Runtime {
    private static let initCode: Int32 = libssh2_init(0)

    static func ensureInitialized() -> Bool {
        initCode == 0
    }
}
