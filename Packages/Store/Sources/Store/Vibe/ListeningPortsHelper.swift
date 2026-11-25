import Foundation

/// A TCP port currently listening on a remote host.
public struct ListeningPort: Identifiable, Sendable, Equatable, Hashable {
    public var id: UInt16 { port }
    public let port: UInt16
    public let address: String
    public let processName: String?
    public let isLikelyDevServer: Bool

    public init(
        port: UInt16,
        address: String,
        processName: String? = nil,
        isLikelyDevServer: Bool? = nil
    ) {
        self.port = port
        self.address = address
        self.processName = processName
        self.isLikelyDevServer = isLikelyDevServer
            ?? ListeningPortsHelper.isLikelyDevServer(port: port, processName: processName)
    }
}

/// Portable command builder and multi-tool output parser (`ss`, `lsof`, `netstat`) for listening TCP ports.
public enum ListeningPortsHelper {
    /// Well-known local/remote development server ports prioritized in port-forwarding suggestions.
    public static let commonDevPorts: Set<UInt16> = [
        3000, 3001, 3002,
        4000, 4200, 4321,
        5000, 5173, 5174, 5175,
        8000, 8080, 8081, 8443, 8888,
        9000, 1313,
    ]

    private static let exactDevProcessTokens: Set<String> = [
        "bun", "deno", "go", "cargo", "hugo", "rails", "vite", "next", "nextjs",
    ]

    private static let prefixDevProcessTokens: [String] = [
        "node", "python", "uvicorn", "gunicorn", "ruby", "php", "webpack",
    ]

    /// Builds a portable Linux + macOS POSIX command that lists listening TCP sockets.
    public static func listListeningPortsCommand() -> String {
        "PATH=\"$PATH:/usr/sbin:/sbin\"; if command -v ss >/dev/null 2>&1; then ss -tlnp 2>/dev/null || ss -tln 2>/dev/null; elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null; elif command -v netstat >/dev/null 2>&1; then netstat -tln 2>/dev/null; fi || true"
    }

    /// Parses listening TCP ports from `ss`, `lsof`, or `netstat` output, deduplicating by port and sorting dev servers first.
    public static func parseListeningPorts(from output: String, includeSSH: Bool = false) -> [ListeningPort] {
        var byPort: [UInt16: ListeningPort] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            guard let parsed = parseLine(line) else { continue }
            if parsed.port == 22 && !includeSSH {
                continue
            }

            if let existing = byPort[parsed.port] {
                if shouldReplace(existing: existing, with: parsed) {
                    byPort[parsed.port] = parsed
                }
            } else {
                byPort[parsed.port] = parsed
            }
        }

        return byPort.values.sorted { lhs, rhs in
            if lhs.isLikelyDevServer != rhs.isLikelyDevServer {
                return lhs.isLikelyDevServer && !rhs.isLikelyDevServer
            }
            return lhs.port < rhs.port
        }
    }

    /// Returns `true` if `port` is a known dev-server port or `processName` matches a common dev runtime/framework.
    static func isLikelyDevServer(port: UInt16, processName: String?) -> Bool {
        if commonDevPorts.contains(port) {
            return true
        }
        guard let processName else { return false }
        let normalized = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let basename = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let tokens = basename.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        for token in tokens {
            if exactDevProcessTokens.contains(token) {
                return true
            }
            if prefixDevProcessTokens.contains(where: { token.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Private Line Parsers

    private static func parseLine(_ line: String) -> ListeningPort? {
        if line.contains("(LISTEN)") {
            return parseLsofLine(line)
        }

        let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !columns.isEmpty else { return nil }

        let firstLower = columns[0].lowercased()
        if firstLower == "listen" || (columns.count >= 5 && columns[1].lowercased() == "listen") {
            return parseSSLine(line, columns: columns)
        }

        if firstLower.hasPrefix("tcp"), columns.last?.lowercased() == "listen" {
            return parseNetstatLine(columns: columns)
        }

        return nil
    }

    private static func parseSSLine(_ line: String, columns: [String]) -> ListeningPort? {
        let localIndex = columns[0].lowercased() == "listen" ? 3 : 4
        guard columns.count > localIndex else { return nil }
        guard let (address, port) = parseEndpoint(columns[localIndex], allowDotSeparator: false) else {
            return nil
        }
        let processName = extractSSProcessName(from: line)
        return ListeningPort(port: port, address: address, processName: processName)
    }

    private static func parseLsofLine(_ line: String) -> ListeningPort? {
        let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard columns.count >= 4, let listenIdx = columns.lastIndex(of: "(LISTEN)"), listenIdx >= 1 else {
            return nil
        }

        let endpointToken = columns[listenIdx - 1]
        guard let (address, port) = parseEndpoint(endpointToken, allowDotSeparator: false) else {
            return nil
        }

        let rawCommand = columns[0]
            .replacingOccurrences(of: "\\x20", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processName = rawCommand.isEmpty ? nil : rawCommand

        return ListeningPort(port: port, address: address, processName: processName)
    }

    private static func parseNetstatLine(columns: [String]) -> ListeningPort? {
        guard columns.count >= 5 else { return nil }
        guard let (address, port) = parseEndpoint(columns[3], allowDotSeparator: true) else {
            return nil
        }
        return ListeningPort(port: port, address: address, processName: nil)
    }

    private static func extractSSProcessName(from line: String) -> String? {
        guard let usersRange = line.range(of: "users:((\"") else { return nil }
        let remainder = line[usersRange.upperBound...]
        guard let closingQuote = remainder.firstIndex(of: "\"") else { return nil }
        let name = String(remainder[..<closingQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func parseEndpoint(_ raw: String, allowDotSeparator: Bool) -> (address: String, port: UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bracketed IPv6: [::1]:5173 or [::ffff:127.0.0.1]:8000
        if trimmed.hasPrefix("["), let closeBracket = trimmed.range(of: "]:") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket.lowerBound])
            let portString = String(trimmed[closeBracket.upperBound...])
            guard let port = UInt16(portString), port > 0 else { return nil }
            return (host, port)
        }

        let colonIdx = trimmed.lastIndex(of: ":")
        let dotIdx = allowDotSeparator ? trimmed.lastIndex(of: ".") : nil

        let separatorIdx: String.Index?
        if let dotIdx, colonIdx == nil || dotIdx > colonIdx! {
            separatorIdx = dotIdx
        } else {
            separatorIdx = colonIdx
        }

        guard let splitIdx = separatorIdx else { return nil }
        let host = String(trimmed[..<splitIdx])
        let portString = String(trimmed[trimmed.index(after: splitIdx)...])
        guard !host.isEmpty, let port = UInt16(portString), port > 0 else { return nil }
        return (host, port)
    }

    private static func shouldReplace(existing: ListeningPort, with candidate: ListeningPort) -> Bool {
        let existingHasName = !(existing.processName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let candidateHasName = !(candidate.processName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if existingHasName != candidateHasName {
            return candidateHasName
        }

        // Prefer loopback addresses over wildcard binds when process metadata is equal.
        let isLoopback: (String) -> Bool = { addr in
            addr == "127.0.0.1" || addr == "::1" || addr == "localhost"
        }
        return !isLoopback(existing.address) && isLoopback(candidate.address)
    }
}
