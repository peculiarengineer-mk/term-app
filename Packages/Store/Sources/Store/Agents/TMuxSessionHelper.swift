import Foundation

/// Pure, POSIX-shell-safe command builder and parser for managing `tmux`-backed AI agent sessions.
public enum TMuxSessionHelper {
    public static let sessionPrefix = "termapp-ai-"

    private static let standardPATH = "$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
    private static let bracketedPasteBegin = "\u{1B}[200~"
    private static let bracketedPasteEnd = "\u{1B}[201~"

    /// Parsed metadata for a remote `tmux` session returned by `listSessionsCommand()`.
    public struct RemoteAISession: Identifiable, Codable, Sendable, Hashable {
        public let id: String
        public var sessionName: String
        public var agentSlug: String
        public var projectSlug: String
        public var isAttached: Bool
        public var windowCount: Int
        public var createdAt: Date?
        public var lastActivityAt: Date?
        public var currentPath: String?

        public init(
            sessionName: String,
            agentSlug: String,
            projectSlug: String,
            isAttached: Bool,
            windowCount: Int,
            createdAt: Date? = nil,
            lastActivityAt: Date? = nil,
            currentPath: String? = nil
        ) {
            self.id = sessionName
            self.sessionName = sessionName
            self.agentSlug = agentSlug
            self.projectSlug = projectSlug
            self.isAttached = isAttached
            self.windowCount = windowCount
            self.createdAt = createdAt
            self.lastActivityAt = lastActivityAt
            self.currentPath = currentPath
        }
    }

    /// Parsed subdirectory listing returned by `listDirectoriesCommand(in:)`.
    public struct RemoteDirectoryListing: Codable, Sendable, Equatable {
        public var currentPath: String
        public var directories: [String]

        public init(currentPath: String, directories: [String]) {
            self.currentPath = currentPath
            self.directories = directories
        }
    }

    // MARK: - Quoting & Naming

    /// Wraps `value` in POSIX single quotes, escaping embedded single quotes as `'\''`.
    public static func shellQuote(_ value: String) -> String {
        let withoutNul = value.replacingOccurrences(of: "\0", with: "")
        let escaped = withoutNul.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Builds a deterministic, `tmux`-safe session name (`[a-z0-9-]`), e.g. `termapp-ai-claude-term-app`.
    public static func sessionName(agentSlug: String, workingDirectory: String) -> String {
        let safeAgent = sanitizeSlug(agentSlug, maxLength: 20, fallback: "agent")
        let projectSlug = projectSlug(from: workingDirectory)
        return "\(sessionPrefix)\(safeAgent)-\(projectSlug)"
    }

    /// Expands a leading `~` / `~/` safely into `"$HOME"` while single-quoting literal path suffixes.
    static func shellPathExpression(for path: String) -> String {
        let cleaned = path
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .newlines)
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" || trimmed == "~/" {
            return "\"$HOME\""
        }
        if cleaned.hasPrefix("~/") {
            let rest = String(cleaned.dropFirst(2))
            if rest.isEmpty {
                return "\"$HOME\""
            }
            return "\"$HOME\"/\(shellQuote(rest))"
        }
        return shellQuote(cleaned)
    }

    /// Sanitizes an arbitrary string into a lowercase `[a-z0-9-]` slug bounded to `maxLength`.
    static func sanitizeSlug(_ raw: String, maxLength: Int = 32, fallback: String) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var result = ""
        result.reserveCapacity(min(folded.count, maxLength))
        var pendingHyphen = false

        for scalar in folded.unicodeScalars {
            let isASCIIAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isASCIIAlnum {
                if pendingHyphen && !result.isEmpty {
                    if result.count + 1 >= maxLength { break }
                    result.append("-")
                }
                pendingHyphen = false
                if result.count >= maxLength { break }
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty {
                pendingHyphen = true
            }
        }

        while result.hasSuffix("-") {
            result.removeLast()
        }

        return result.isEmpty ? fallback : result
    }

    private static func projectSlug(from workingDirectory: String) -> String {
        var trimmed = workingDirectory
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed == "~" || trimmed == "~/" || trimmed == "$HOME" || trimmed == "$HOME/" {
            return "home"
        }
        if trimmed == "/" {
            return "root"
        }

        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        let basename: String
        if let lastSlash = trimmed.lastIndex(of: "/") {
            basename = String(trimmed[trimmed.index(after: lastSlash)...])
        } else {
            basename = trimmed
        }

        if basename == "." || basename == ".." {
            return "home"
        }
        return sanitizeSlug(basename, maxLength: 28, fallback: "project")
    }

    // MARK: - Command Generation

    /// Builds a single-line POSIX command that creates or reattaches a `tmux` session running `agent`.
    ///
    /// Prepends common CLI tool directories to `PATH` if not already present, handles `~/` expansion
    /// safely, drops to `$SHELL` if the agent exits so diagnostics remain visible, and prints a clear
    /// fallback message before running directly if `tmux` is not installed on the host.
    public static func launchOrAttachCommand(
        agent: AIAgentDescriptor,
        workingDirectory: String,
        extraArgs: String = "",
        sessionName: String? = nil
    ) -> String {
        let resolvedName: String = {
            if let sessionName {
                let trimmed = sessionName
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return Self.sessionName(agentSlug: agent.slug, workingDirectory: workingDirectory)
        }()

        let quotedSession = shellQuote(resolvedName)
        let dirExpr = shellPathExpression(for: workingDirectory)

        let commandParts = [agent.command, agent.defaultArgs, extraArgs]
            .map {
                $0.replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let agentCmd = commandParts.isEmpty ? "\"${SHELL:-sh}\"" : commandParts.joined(separator: " ")

        let pathExport = "export PATH=\"\(standardPATH):$PATH\""
        let guardedPathExport = "case \":$PATH:\" in *\":\(standardPATH):\"*) ;; *) \(pathExport);; esac"

        let innerPathPrefix = agentCmd.contains("export PATH=") ? "" : "\(pathExport); "
        let innerScript =
            "\(innerPathPrefix)\(agentCmd); _st=$?; printf \"\\n[agent exited (%s) - starting shell]\\n\" \"$_st\"; exec \"${SHELL:-sh}\" -l"
        let quotedInnerCmd = shellQuote("sh -lc \(shellQuote(innerScript))")

        let missingTmuxNotice = shellQuote(
            "tmux is not installed on this host. Install tmux for persistent AI sessions - running directly in this shell."
        )

        return "\(guardedPathExport); if command -v tmux >/dev/null 2>&1; then tmux new-session -A -s \(quotedSession) -c \(dirExpr) \(quotedInnerCmd); else printf '%s\\n' \(missingTmuxNotice); cd -- \(dirExpr) && { \(agentCmd); }; fi"
    }

    /// Builds a POSIX command to attach to an existing `tmux` session.
    public static func attachCommand(sessionName: String) -> String {
        let quoted = shellQuote(sessionName)
        return "export PATH=\"\(standardPATH):$PATH\"; tmux attach-session -t \(quoted)"
    }

    /// Builds a POSIX command to kill a specific `tmux` session.
    public static func killSessionCommand(sessionName: String) -> String {
        let quoted = shellQuote(sessionName)
        return "export PATH=\"\(standardPATH):$PATH\"; tmux kill-session -t \(quoted)"
    }

    /// Builds a POSIX command to list `tmux` sessions in tab-delimited format.
    public static func listSessionsCommand() -> String {
        let format = "#{session_name}\\t#{session_attached}\\t#{session_windows}\\t#{session_created}\\t#{session_activity}\\t#{pane_current_path}"
        return "export PATH=\"\(standardPATH):$PATH\"; tmux list-sessions -F \"$(printf '\(format)')\" 2>/dev/null || true"
    }

    /// Builds a POSIX command that expands `path`, prints `PWD:<resolved>` on line 1, and lists sorted non-hidden subdirectories.
    public static func listDirectoriesCommand(in path: String) -> String {
        let dirExpr = shellPathExpression(for: path)
        let inner = "cd -- \"$1\" 2>/dev/null && { printf \"PWD:%s\\n\" \"$(pwd)\"; for _d in */; do [ -d \"$_d\" ] && printf \"%s\\n\" \"${_d%/}\"; done | LC_ALL=C sort; } || true"
        return "sh -c \(shellQuote(inner)) _ \(dirExpr)"
    }

    // MARK: - Output Parsers

    /// Parses output from `listSessionsCommand()` into structured session records.
    public static func parseSessions(from output: String, onlyTermAppManaged: Bool = true) -> [RemoteAISession] {
        var sessions: [RemoteAISession] = []

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let fields: [String]
            if line.contains("\t") {
                fields = line.components(separatedBy: "\t")
            } else if line.contains("\\t") {
                fields = line.components(separatedBy: "\\t")
            } else {
                continue
            }

            guard fields.count >= 3 else { continue }

            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            guard let attachedInt = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  let windowCount = Int(fields[2].trimmingCharacters(in: .whitespaces))
            else {
                continue
            }

            let isManaged = name.hasPrefix(sessionPrefix)
            if onlyTermAppManaged && !isManaged {
                continue
            }

            let (agentSlug, projectSlug) = parseSlugs(from: name, isManaged: isManaged)
            if onlyTermAppManaged && agentSlug.isEmpty {
                continue
            }

            let createdAt = fields.count > 3 ? parseTimestamp(fields[3]) : nil
            let lastActivityAt = fields.count > 4 ? parseTimestamp(fields[4]) : nil
            let currentPath: String? = {
                guard fields.count > 5 else { return nil }
                let path = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }()

            sessions.append(
                RemoteAISession(
                    sessionName: name,
                    agentSlug: agentSlug,
                    projectSlug: projectSlug,
                    isAttached: attachedInt > 0,
                    windowCount: windowCount,
                    createdAt: createdAt,
                    lastActivityAt: lastActivityAt,
                    currentPath: currentPath
                )
            )
        }

        return sessions
    }

    /// Parses output from `listDirectoriesCommand(in:)` into `RemoteDirectoryListing`.
    public static func parseDirectoryListing(from output: String) -> RemoteDirectoryListing {
        var currentPath = ""
        var directories: [String] = []

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { continue }

            if line.hasPrefix("PWD:") {
                var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                while path.count > 1 && path.hasSuffix("/") {
                    path.removeLast()
                }
                currentPath = path
                continue
            }

            var entry = line
            while entry.count > 1 && entry.hasSuffix("/") {
                entry.removeLast()
            }
            if entry == "/" || entry.isEmpty || entry == "." || entry == ".." {
                continue
            }
            directories.append(entry)
        }

        return RemoteDirectoryListing(currentPath: currentPath, directories: directories)
    }

    // MARK: - Bracketed Paste

    /// Wraps `prompt` in ANSI bracketed paste sequences (`ESC[200~ ... ESC[201~`) with optional `\r` submission.
    ///
    /// Strips any embedded bracketed-paste sequences recursively so untrusted text cannot break out of paste mode.
    public static func bracketedPastePayload(for prompt: String, submit: Bool = true) -> Data {
        var sanitized = prompt
        while sanitized.contains(bracketedPasteEnd) || sanitized.contains(bracketedPasteBegin) {
            sanitized = sanitized
                .replacingOccurrences(of: bracketedPasteEnd, with: "")
                .replacingOccurrences(of: bracketedPasteBegin, with: "")
        }

        var payload = "\(bracketedPasteBegin)\(sanitized)\(bracketedPasteEnd)"
        if submit {
            payload.append("\r")
        }
        return Data(payload.utf8)
    }

    // MARK: - Private Parsing Helpers

    private static func parseSlugs(from sessionName: String, isManaged: Bool) -> (agent: String, project: String) {
        guard isManaged else { return ("", "") }
        let remainder = String(sessionName.dropFirst(sessionPrefix.count))
        guard !remainder.isEmpty else { return ("", "") }

        for builtIn in BuiltInAIAgent.allCases {
            let prefix = "\(builtIn.rawValue)-"
            if remainder.hasPrefix(prefix) {
                return (builtIn.rawValue, String(remainder.dropFirst(prefix.count)))
            }
            if remainder == builtIn.rawValue {
                return (builtIn.rawValue, "")
            }
        }

        if let hyphenIndex = remainder.firstIndex(of: "-") {
            let agent = String(remainder[..<hyphenIndex])
            let project = String(remainder[remainder.index(after: hyphenIndex)...])
            return (agent, project)
        }

        return (remainder, "")
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let seconds = TimeInterval(trimmed), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
