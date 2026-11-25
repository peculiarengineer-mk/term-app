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

    /// Package managers detected on a remote host for 1-tap `tmux` installation.
    public enum RemotePackageManager: String, Codable, Sendable, Equatable, CaseIterable {
        case brew
        case apt
        case dnf
        case yum
        case pacman
        case apk
        case zypper
        case pkg
        case unknown

        public var displayName: String {
            switch self {
            case .brew: "Homebrew"
            case .apt: "APT"
            case .dnf: "DNF"
            case .yum: "YUM"
            case .pacman: "Pacman"
            case .apk: "APK"
            case .zypper: "Zypper"
            case .pkg: "pkg"
            case .unknown: "Unknown"
            }
        }
    }

    /// Result of probing a remote host for `tmux`, root privilege, and available package manager.
    public struct TMuxAvailability: Codable, Sendable, Equatable {
        public let isInstalled: Bool
        public let packageManager: RemotePackageManager
        public let isRoot: Bool

        public init(isInstalled: Bool, packageManager: RemotePackageManager, isRoot: Bool) {
            self.isInstalled = isInstalled
            self.packageManager = packageManager
            self.isRoot = isRoot
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
    public static func shellPathExpression(for path: String) -> String {
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

    /// Builds a POSIX command to attach to an existing `tmux` session only if `tmux` is installed.
    public static func safeAttachCommand(sessionName: String) -> String {
        let quoted = shellQuote(sessionName)
        return "export PATH=\"\(standardPATH):$PATH\"; if command -v tmux >/dev/null 2>&1; then tmux attach-session -t \(quoted); fi"
    }

    /// Builds a POSIX command that checks whether `tmux` is installed, whether the user is root, and which package manager is available.
    public static func checkTmuxCommand() -> String {
        let pathExport = "export PATH=\"\(standardPATH):$PATH\""
        let tmuxCheck = "if command -v tmux >/dev/null 2>&1; then printf 'TMUX:INSTALLED\\n'; else printf 'TMUX:MISSING\\n'; fi"
        let rootCheck = "if [ \"$(id -u 2>/dev/null)\" = \"0\" ]; then printf 'ROOT:1\\n'; else printf 'ROOT:0\\n'; fi"
        let pmCheck = [
            "if command -v brew >/dev/null 2>&1; then printf 'PM:brew\\n'",
            "elif command -v apt-get >/dev/null 2>&1; then printf 'PM:apt\\n'",
            "elif command -v dnf >/dev/null 2>&1; then printf 'PM:dnf\\n'",
            "elif command -v yum >/dev/null 2>&1; then printf 'PM:yum\\n'",
            "elif command -v pacman >/dev/null 2>&1; then printf 'PM:pacman\\n'",
            "elif command -v apk >/dev/null 2>&1; then printf 'PM:apk\\n'",
            "elif command -v zypper >/dev/null 2>&1; then printf 'PM:zypper\\n'",
            "elif command -v pkg >/dev/null 2>&1; then printf 'PM:pkg\\n'",
            "else printf 'PM:unknown\\n'; fi",
        ].joined(separator: "; ")
        return "\(pathExport); \(tmuxCheck); \(rootCheck); \(pmCheck)"
    }

    /// Builds a POSIX command to install `tmux` with the given package manager, or `nil` for `.unknown`.
    public static func installTmuxCommand(
        packageManager: RemotePackageManager,
        isRoot: Bool,
        interactive: Bool
    ) -> String? {
        let pathPrefix = "export PATH=\"\(standardPATH):$PATH\"; "
        let installStep: String
        switch packageManager {
        case .unknown:
            return nil
        case .brew:
            // Homebrew refuses to run as root and manages its own prefix permissions.
            installStep = "brew install tmux"
        case .apt:
            if isRoot {
                installStep = "DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux"
            } else if !interactive {
                installStep = "sudo -n sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux'"
            } else {
                installStep = "sudo apt-get update && sudo apt-get install -y tmux"
            }
        case .dnf:
            installStep = sudoWrapped("dnf install -y tmux", isRoot: isRoot, interactive: interactive)
        case .yum:
            installStep = sudoWrapped("yum install -y tmux", isRoot: isRoot, interactive: interactive)
        case .pacman:
            installStep = sudoWrapped("pacman -Sy --noconfirm tmux", isRoot: isRoot, interactive: interactive)
        case .apk:
            installStep = sudoWrapped("apk add --no-cache tmux", isRoot: isRoot, interactive: interactive)
        case .zypper:
            installStep = sudoWrapped("zypper --non-interactive install tmux", isRoot: isRoot, interactive: interactive)
        case .pkg:
            installStep = sudoWrapped("pkg install -y tmux", isRoot: isRoot, interactive: interactive)
        }
        return pathPrefix + installStep
    }

    private static func sudoWrapped(_ command: String, isRoot: Bool, interactive: Bool) -> String {
        if isRoot { return command }
        return interactive ? "sudo \(command)" : "sudo -n \(command)"
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

    /// Parses output from `checkTmuxCommand()` into `TMuxAvailability`.
    public static func parseTmuxAvailability(from output: String) -> TMuxAvailability {
        var isInstalled = false
        var isRoot = false
        var packageManager: RemotePackageManager = .unknown

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line == "TMUX:INSTALLED" {
                isInstalled = true
            } else if line == "TMUX:MISSING" {
                isInstalled = false
            } else if line == "ROOT:1" {
                isRoot = true
            } else if line == "ROOT:0" {
                isRoot = false
            } else if line.hasPrefix("PM:") {
                let rawPM = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                packageManager = RemotePackageManager(rawValue: rawPM) ?? .unknown
            }
        }

        return TMuxAvailability(
            isInstalled: isInstalled,
            packageManager: packageManager,
            isRoot: isRoot
        )
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
