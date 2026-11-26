import Foundation

/// Errors thrown when resolving a `Host` ProxyJump bastion chain.
public enum ProxyJumpError: Error, LocalizedError, Equatable, Sendable {
    case cycleDetected
    case maxHopsExceeded(Int)
    case jumpHostNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .cycleDetected:
            "ProxyJump configuration contains a cycle."
        case .maxHopsExceeded(let maxHops):
            "ProxyJump chain exceeds the maximum of \(maxHops) hops."
        case .jumpHostNotFound(let hostID):
            "ProxyJump host (\(hostID.uuidString)) could not be found."
        }
    }
}

/// Resolves ordered ProxyJump bastion chains for saved `Host` records.
public enum ProxyJumpResolver {
    /// Resolves the ordered jump-host chain `[jump1, jump2, ...]` from outermost bastion to immediate
    /// jump host for `target`, or `[]` if `target.proxyJumpHostID == nil`.
    public static func resolveChain(
        for target: Host,
        allHosts: [Host],
        maxHops: Int = 5
    ) throws -> [Host] {
        guard target.proxyJumpHostID != nil else { return [] }

        let hostsByID = Dictionary(
            allHosts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var visited: Set<UUID> = [target.id]
        var reversedChain: [Host] = []
        var current = target

        while let jumpID = current.proxyJumpHostID {
            if visited.contains(jumpID) {
                throw ProxyJumpError.cycleDetected
            }
            if reversedChain.count >= maxHops {
                throw ProxyJumpError.maxHopsExceeded(maxHops)
            }
            guard let jumpHost = hostsByID[jumpID] else {
                throw ProxyJumpError.jumpHostNotFound(jumpID)
            }
            visited.insert(jumpID)
            reversedChain.append(jumpHost)
            current = jumpHost
        }

        return reversedChain.reversed()
    }
}
