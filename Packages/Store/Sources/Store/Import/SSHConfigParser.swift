import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A concrete host entry extracted from an OpenSSH client configuration (`~/.ssh/config`).
public struct SSHConfigEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityFile: String?
    public var proxyJump: String?
    public var forwardAgent: Bool

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        port: Int = 22,
        username: String = "",
        identityFile: String? = nil,
        proxyJump: String? = nil,
        forwardAgent: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.forwardAgent = forwardAgent
    }
}

/// Parses OpenSSH `~/.ssh/config` text into concrete host entries.
public enum SSHConfigParser {
    private enum ProxyJumpSetting {
        case disabled
        case jump(String)

        var value: String? {
            switch self {
            case .disabled: nil
            case .jump(let target): target
            }
        }
    }

    private struct PartialHost {
        var hostname: String?
        var username: String?
        var port: Int?
        var identityFile: String?
        var proxyJump: ProxyJumpSetting?
        var forwardAgent: Bool?

        mutating func apply(key: String, tokens: [String]) {
            guard let first = tokens.first else { return }
            switch key {
            case "hostname":
                if hostname == nil { hostname = first }
            case "user":
                if username == nil { username = first }
            case "port":
                if port == nil, let parsed = Int(first), (1...65535).contains(parsed) {
                    port = parsed
                }
            case "identityfile":
                if identityFile == nil, !first.isEmpty { identityFile = first }
            case "proxyjump":
                if proxyJump == nil, !first.isEmpty {
                    if first.caseInsensitiveCompare("none") == .orderedSame {
                        proxyJump = .disabled
                    } else {
                        proxyJump = .jump(first)
                    }
                }
            case "forwardagent":
                if forwardAgent == nil, let parsed = Self.parseBool(first) {
                    forwardAgent = parsed
                }
            default:
                break
            }
        }

        private static func parseBool(_ token: String) -> Bool? {
            switch token.lowercased() {
            case "yes", "true", "1":
                return true
            case "no", "false", "0":
                return false
            default:
                return nil
            }
        }
    }

    private enum ActiveTarget {
        case globals
        case hosts([String])
        case ignored
    }

    public static func parse(_ text: String) -> [SSHConfigEntry] {
        var globalDefaults = PartialHost()
        var orderedAliases: [String] = []
        var hostsByAlias: [String: PartialHost] = [:]
        var active: ActiveTarget = .globals

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (key, tokens) = parseLine(rawLine) else { continue }

            switch key {
            case "host":
                if tokens == ["*"] {
                    active = .globals
                    continue
                }
                let concreteAliases = tokens.filter { !isWildcardOrNegated($0) }
                if concreteAliases.isEmpty {
                    active = .ignored
                    continue
                }
                for alias in concreteAliases where hostsByAlias[alias] == nil {
                    orderedAliases.append(alias)
                    hostsByAlias[alias] = PartialHost()
                }
                active = .hosts(concreteAliases)
            case "match":
                active = .ignored
            default:
                switch active {
                case .globals:
                    globalDefaults.apply(key: key, tokens: tokens)
                case .hosts(let aliases):
                    for alias in aliases {
                        hostsByAlias[alias]?.apply(key: key, tokens: tokens)
                    }
                case .ignored:
                    break
                }
            }
        }

        return orderedAliases.compactMap { alias in
            guard let partial = hostsByAlias[alias] else { return nil }
            let resolvedHostname: String
            if let explicitHost = partial.hostname {
                let expanded = expandHostNameTokens(explicitHost, alias: alias)
                guard !expanded.isEmpty else { return nil }
                resolvedHostname = expanded
            } else if looksLikeHostnameOrIP(alias) {
                resolvedHostname = alias
            } else {
                return nil
            }

            return SSHConfigEntry(
                alias: alias,
                hostname: resolvedHostname,
                port: partial.port ?? globalDefaults.port ?? 22,
                username: partial.username ?? globalDefaults.username ?? "",
                identityFile: partial.identityFile ?? globalDefaults.identityFile,
                proxyJump: (partial.proxyJump ?? globalDefaults.proxyJump)?.value,
                forwardAgent: partial.forwardAgent ?? globalDefaults.forwardAgent ?? false
            )
        }
    }

    private static func isWildcardOrNegated(_ pattern: String) -> Bool {
        pattern.isEmpty || pattern.contains("*") || pattern.contains("?") || pattern.contains("!")
    }

    private static func looksLikeHostnameOrIP(_ alias: String) -> Bool {
        guard !alias.isEmpty, !alias.contains(where: \.isWhitespace) else { return false }
        if alias.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if isValidIPv6(alias) { return true }
        if alias.contains(".") {
            let parts = alias.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
        }
        return false
    }

    private static func isValidIPv6(_ string: String) -> Bool {
        var addr = in6_addr()
        return string.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static func expandHostNameTokens(_ template: String, alias: String) -> String {
        var result = ""
        result.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            let next = template.index(after: index)
            if ch == "%", next < template.endIndex {
                switch template[next] {
                case "h", "n":
                    result.append(alias)
                    index = template.index(after: next)
                    continue
                case "%":
                    result.append("%")
                    index = template.index(after: next)
                    continue
                default:
                    break
                }
            }
            result.append(ch)
            index = next
        }
        return result
    }

    private static func parseLine(_ rawLine: Substring) -> (key: String, tokens: [String])? {
        let stripped = stripCommentOutsideQuotes(rawLine)
        var idx = stripped.startIndex
        skipWhitespace(in: stripped, index: &idx)
        guard idx < stripped.endIndex else { return nil }

        let keyStart = idx
        while idx < stripped.endIndex {
            let ch = stripped[idx]
            if ch.isWhitespace || ch == "=" { break }
            idx = stripped.index(after: idx)
        }
        let key = String(stripped[keyStart..<idx]).lowercased()
        guard !key.isEmpty else { return nil }

        skipWhitespace(in: stripped, index: &idx)
        if idx < stripped.endIndex, stripped[idx] == "=" {
            idx = stripped.index(after: idx)
            skipWhitespace(in: stripped, index: &idx)
        }

        let tokens = tokenizeArguments(stripped[idx...])
        return tokens.isEmpty ? nil : (key, tokens)
    }

    private static func stripCommentOutsideQuotes(_ line: Substring) -> String {
        var result = ""
        var inDoubleQuotes = false
        for ch in line {
            if inDoubleQuotes {
                if ch == "\"" {
                    inDoubleQuotes = false
                }
                result.append(ch)
            } else if ch == "\"" {
                inDoubleQuotes = true
                result.append(ch)
            } else if ch == "#" {
                break
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func skipWhitespace(in s: String, index: inout String.Index) {
        while index < s.endIndex, s[index].isWhitespace {
            index = s.index(after: index)
        }
    }

    private static func tokenizeArguments(_ slice: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inDoubleQuotes = false

        for ch in slice {
            if inDoubleQuotes {
                if ch == "\"" {
                    inDoubleQuotes = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inDoubleQuotes = true
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }
}
