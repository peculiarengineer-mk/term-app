import Foundation

/// A concrete host entry extracted from an OpenSSH client configuration (`~/.ssh/config`).
public struct SSHConfigEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityFile: String?

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        port: Int = 22,
        username: String = "",
        identityFile: String? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityFile = identityFile
    }
}

/// Parses OpenSSH `~/.ssh/config` text into concrete host entries.
public enum SSHConfigParser {
    private struct PartialHost {
        var hostname: String?
        var username: String?
        var port: Int?
        var identityFile: String?

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
            default:
                break
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
                guard !explicitHost.isEmpty else { return nil }
                resolvedHostname = explicitHost
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
                identityFile: partial.identityFile ?? globalDefaults.identityFile
            )
        }
    }

    private static func isWildcardOrNegated(_ pattern: String) -> Bool {
        pattern.isEmpty || pattern.contains("*") || pattern.contains("?") || pattern.contains("!")
    }

    private static func looksLikeHostnameOrIP(_ alias: String) -> Bool {
        guard !alias.isEmpty, !alias.contains(where: \.isWhitespace) else { return false }
        if alias.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if alias.contains(":") { return alias.contains(where: { $0 != ":" }) }
        if alias.contains(".") {
            let parts = alias.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
        }
        return false
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
        var quote: Character?
        for ch in line {
            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                }
                result.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
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
        var quote: Character?

        for ch in slice {
            if let activeQuote = quote {
                if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
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
