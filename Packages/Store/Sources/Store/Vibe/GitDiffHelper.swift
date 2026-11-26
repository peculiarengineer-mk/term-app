import Foundation

/// A single changed entry reported by `git status --porcelain=v1`.
public struct GitChangedFile: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public let path: String
    public let indexStatus: Character
    public let workTreeStatus: Character
    public let isStaged: Bool
    public let isUntracked: Bool
    public let displayBadge: String

    public init(
        path: String,
        indexStatus: Character,
        workTreeStatus: Character,
        isStaged: Bool? = nil,
        isUntracked: Bool? = nil,
        displayBadge: String? = nil
    ) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        let derivedUntracked = (indexStatus == "?" && workTreeStatus == "?")
        let derivedStaged = !derivedUntracked && indexStatus != " " && indexStatus != "!"
        self.isUntracked = isUntracked ?? derivedUntracked
        self.isStaged = isStaged ?? derivedStaged
        self.displayBadge = displayBadge ?? Self.badge(indexStatus: indexStatus, workTreeStatus: workTreeStatus)
    }

    private static func badge(indexStatus: Character, workTreeStatus: Character) -> String {
        if indexStatus == "?" && workTreeStatus == "?" {
            return "??"
        }
        let primary = (indexStatus != " " && indexStatus != "?") ? indexStatus : workTreeStatus
        switch primary {
        case "M", "A", "D", "R":
            return String(primary)
        case "C":
            return "A"
        case "T":
            return "M"
        default:
            return String(primary)
        }
    }
}

/// Semantic line classification within a unified git diff.
public enum GitDiffLineKind: String, Sendable, Equatable, Hashable {
    case header
    case hunk
    case added
    case removed
    case context
}

/// A single line in a parsed unified file diff.
public struct GitDiffLine: Identifiable, Sendable, Equatable, Hashable {
    public let id: Int
    public let kind: GitDiffLineKind
    public let text: String

    public init(id: Int, kind: GitDiffLineKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Parsed unified diff for a single repository file.
public struct GitFileDiff: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let lines: [GitDiffLine]

    public init(path: String, additions: Int, deletions: Int, lines: [GitDiffLine]) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.lines = lines
    }
}

/// Combined repository metadata, working-tree file statuses, and unified diffs.
public struct GitRepoSnapshot: Sendable, Equatable {
    public let repoRoot: String
    public let branch: String
    public let files: [GitChangedFile]
    public let diffs: [GitFileDiff]
    public let rawDiff: String
    public let isGitRepo: Bool

    public init(
        repoRoot: String = "",
        branch: String = "",
        files: [GitChangedFile] = [],
        diffs: [GitFileDiff] = [],
        rawDiff: String = "",
        isGitRepo: Bool = false
    ) {
        self.repoRoot = repoRoot
        self.branch = branch
        self.files = files
        self.diffs = diffs
        self.rawDiff = rawDiff
        self.isGitRepo = isGitRepo
    }
}

/// Pure, POSIX-shell-safe command builders and output parsers for inspecting and managing Git diffs.
public enum GitDiffHelper {
    private static let standardPATH = "$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
    private static let notAGitRepoMarker = "NOT_A_GIT_REPO"
    private static let rootPrefix = "TERMAPP_GIT_ROOT:"
    private static let branchPrefix = "TERMAPP_GIT_BRANCH:"
    private static let statusBeginMarker = "TERMAPP_GIT_STATUS_BEGIN"
    private static let statusEndMarker = "TERMAPP_GIT_STATUS_END"
    private static let diffBeginMarker = "TERMAPP_GIT_DIFF_BEGIN"
    private static let diffEndMarker = "TERMAPP_GIT_DIFF_END"

    // MARK: - Path Validation

    /// Validates that `path` is a non-empty relative path without NUL, newlines, leading `/`, or `..` traversal components.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.contains("\r"),
              !path.contains("\n"),
              !path.hasPrefix("/")
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") {
            return false
        }
        let meaningful = components.filter { !$0.isEmpty && $0 != "." }
        return !meaningful.isEmpty
    }

    // MARK: - Command Builders

    /// Builds a POSIX-compatible command that prints structured git status and unified diff markers in `directory`.
    public static func statusAndDiffCommand(in directory: String) -> String {
        let dirExpr = TMuxSessionHelper.shellPathExpression(for: directory)
        let pathPrefix = "export PATH=\"\(standardPATH):$PATH\""
        let cdCheck = "cd -- \(dirExpr) 2>/dev/null || { printf '\(notAGitRepoMarker)\\n'; exit 0; }"
        let rootCheck = "_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n \"$_root\" ] || { printf '\(notAGitRepoMarker)\\n'; exit 0; }"
        let printRoot = "printf '\(rootPrefix)%s\\n' \"$_root\""
        let branchCheck = "_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo detached)"
        let printBranch = "printf '\(branchPrefix)%s\\n' \"$_branch\""
        let statusSection = "printf '\(statusBeginMarker)\\n'; git -c core.quotepath=false status --porcelain=v1 2>/dev/null || true; printf '\(statusEndMarker)\\n'"
        let diffBody = "if git rev-parse --verify HEAD >/dev/null 2>&1; then git -c core.quotepath=false diff HEAD --no-color 2>/dev/null || true; else git -c core.quotepath=false diff --no-color 2>/dev/null || true; fi"
        let diffSection = "printf '\(diffBeginMarker)\\n'; \(diffBody); printf '\(diffEndMarker)\\n'"

        return "\(pathPrefix); \(cdCheck); \(rootCheck); \(printRoot); \(branchCheck); \(printBranch); \(statusSection); \(diffSection)"
    }

    /// Builds a POSIX-compatible command that stages all changes and creates a commit with `message`.
    public static func stageAndCommitCommand(in directory: String, message: String) -> String {
        let dirExpr = TMuxSessionHelper.shellPathExpression(for: directory)
        let quotedMessage = TMuxSessionHelper.shellQuote(message)
        return "export PATH=\"\(standardPATH):$PATH\"; cd -- \(dirExpr) && git add -A && git commit -m \(quotedMessage)"
    }

    /// Builds a POSIX-compatible command that discards local modifications to `path` (or removes it when untracked).
    public static func discardFileCommand(in directory: String, path: String, isUntracked: Bool) -> String {
        guard isSafeRelativePath(path) else {
            return "printf '%s\\n' 'Invalid path' >&2; false"
        }
        let dirExpr = TMuxSessionHelper.shellPathExpression(for: directory)
        let quotedPath = TMuxSessionHelper.shellQuote(path)
        let rootCd = "cd -- \(dirExpr) && _root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n \"$_root\" ] && cd -- \"$_root\""

        let action: String
        if isUntracked {
            action = "git clean -fd -- \(quotedPath)"
        } else {
            action = "if git rev-parse --verify HEAD >/dev/null 2>&1; then git reset -q HEAD -- \(quotedPath) && { if git ls-files --error-unmatch -- \(quotedPath) >/dev/null 2>&1; then git checkout -- \(quotedPath); else rm -rf -- \(quotedPath); fi; }; else git rm --cached -q -f -- \(quotedPath) && rm -rf -- \(quotedPath); fi"
        }

        return "export PATH=\"\(standardPATH):$PATH\"; \(rootCd) && \(action)"
    }

    // MARK: - Parsers

    /// Parses the structured marker output emitted by `statusAndDiffCommand(in:)` into a `GitRepoSnapshot`.
    public static func parseSnapshot(from output: String) -> GitRepoSnapshot {
        enum Section {
            case none
            case status
            case diff
        }

        var repoRoot = ""
        var branch = ""
        var statusLines: [String] = []
        var diffLines: [String] = []
        var sawRepoMarker = false
        var activeSection: Section = .none

        for rawLine in splitLinesPreservingSpaces(output) {
            switch activeSection {
            case .status:
                if rawLine == statusEndMarker {
                    activeSection = .none
                } else {
                    statusLines.append(rawLine)
                }
            case .diff:
                if rawLine == diffEndMarker {
                    activeSection = .none
                } else {
                    diffLines.append(rawLine)
                }
            case .none:
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed == notAGitRepoMarker {
                    return GitRepoSnapshot(isGitRepo: false)
                } else if trimmed.hasPrefix(rootPrefix) {
                    sawRepoMarker = true
                    repoRoot = String(trimmed.dropFirst(rootPrefix.count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix(branchPrefix) {
                    sawRepoMarker = true
                    branch = String(trimmed.dropFirst(branchPrefix.count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed == statusBeginMarker {
                    sawRepoMarker = true
                    activeSection = .status
                } else if trimmed == diffBeginMarker {
                    sawRepoMarker = true
                    activeSection = .diff
                }
            }
        }

        guard sawRepoMarker || !repoRoot.isEmpty else {
            return GitRepoSnapshot(isGitRepo: false)
        }

        let statusBlock = statusLines.joined(separator: "\n")
        let rawDiff = diffLines.joined(separator: "\n")
        let files = parsePorcelainStatus(statusBlock)
        let diffs = parseUnifiedDiff(rawDiff)

        return GitRepoSnapshot(
            repoRoot: repoRoot,
            branch: branch,
            files: files,
            diffs: diffs,
            rawDiff: rawDiff,
            isGitRepo: true
        )
    }

    /// Parses `git status --porcelain=v1` output into `GitChangedFile` entries.
    public static func parsePorcelainStatus(_ statusBlock: String) -> [GitChangedFile] {
        var files: [GitChangedFile] = []

        for line in splitLinesPreservingSpaces(statusBlock) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            guard line.count >= 4 else { continue }

            let firstIdx = line.startIndex
            let secondIdx = line.index(after: firstIdx)
            let spaceIdx = line.index(after: secondIdx)
            guard line[spaceIdx] == " " else { continue }

            let indexStatus = line[firstIdx]
            let workTreeStatus = line[secondIdx]
            let rawPath = String(line[line.index(after: spaceIdx)...])
            let resolvedPath = resolvePorcelainPath(
                rawPath,
                isRenameOrCopy: indexStatus == "R" || indexStatus == "C" || workTreeStatus == "R" || workTreeStatus == "C"
            )
            guard !resolvedPath.isEmpty else { continue }

            files.append(
                GitChangedFile(
                    path: resolvedPath,
                    indexStatus: indexStatus,
                    workTreeStatus: workTreeStatus
                )
            )
        }

        return files
    }

    /// Parses unified `git diff` output into per-file diffs with classified lines and addition/deletion counts.
    public static func parseUnifiedDiff(_ diffText: String) -> [GitFileDiff] {
        struct SectionBuilder {
            var path: String
            var additions: Int = 0
            var deletions: Int = 0
            var lines: [GitDiffLine] = []
            var inHunk: Bool = false

            mutating func appendLine(_ text: String, kind: GitDiffLineKind) {
                lines.append(GitDiffLine(id: lines.count, kind: kind, text: text))
            }

            func build() -> GitFileDiff {
                GitFileDiff(path: path, additions: additions, deletions: deletions, lines: lines)
            }
        }

        var builders: [SectionBuilder] = []
        var current: SectionBuilder?

        func flushCurrent() {
            if let section = current {
                builders.append(section)
                current = nil
            }
        }

        for line in splitLinesPreservingSpaces(diffText) {
            if line.hasPrefix("diff --git ") {
                flushCurrent()
                let initialPath = parseDiffGitHeaderPath(line)
                var section = SectionBuilder(path: initialPath)
                section.appendLine(line, kind: .header)
                current = section
                continue
            }

            if current == nil {
                if line.hasPrefix("--- ") {
                    let candidate = stripDiffPathPrefix(String(line.dropFirst(4)), prefix: "a/")
                    var section = SectionBuilder(path: candidate == "/dev/null" ? "" : candidate)
                    section.appendLine(line, kind: .header)
                    current = section
                }
                continue
            }

            guard var section = current else { continue }

            if line.hasPrefix("@@") {
                section.inHunk = true
                section.appendLine(line, kind: .hunk)
            } else if !section.inHunk {
                if line.hasPrefix("rename to ") {
                    let renamed = unquoteCStringIfNeeded(String(line.dropFirst("rename to ".count)))
                    if !renamed.isEmpty {
                        section.path = renamed
                    }
                } else if line.hasPrefix("+++ ") {
                    let plusPath = String(line.dropFirst(4))
                    if plusPath != "/dev/null" {
                        let resolved = stripDiffPathPrefix(plusPath, prefix: "b/")
                        if !resolved.isEmpty {
                            section.path = resolved
                        }
                    }
                } else if line.hasPrefix("--- ") && section.path.isEmpty {
                    let minusPath = String(line.dropFirst(4))
                    if minusPath != "/dev/null" {
                        section.path = stripDiffPathPrefix(minusPath, prefix: "a/")
                    }
                } else if line.hasPrefix("Binary files "),
                          let andRange = line.range(of: " and "),
                          line.hasSuffix(" differ")
                {
                    let rhsStart = andRange.upperBound
                    let rhsEnd = line.index(line.endIndex, offsetBy: -" differ".count)
                    if rhsStart < rhsEnd {
                        let rhs = String(line[rhsStart..<rhsEnd])
                        if rhs != "/dev/null" {
                            section.path = stripDiffPathPrefix(rhs, prefix: "b/")
                        }
                    }
                }
                section.appendLine(line, kind: .header)
            } else if line.hasPrefix("+") {
                section.additions += 1
                section.appendLine(line, kind: .added)
            } else if line.hasPrefix("-") {
                section.deletions += 1
                section.appendLine(line, kind: .removed)
            } else if line.hasPrefix("\\ No newline at end of file") {
                section.appendLine(line, kind: .header)
            } else {
                section.appendLine(line, kind: .context)
            }

            current = section
        }

        flushCurrent()
        return builders
            .map { $0.build() }
            .filter { !$0.path.isEmpty || !$0.lines.isEmpty }
    }

    // MARK: - Private Helpers

    private static func splitLinesPreservingSpaces(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if text.hasSuffix("\n"), let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func resolvePorcelainPath(_ rawPath: String, isRenameOrCopy: Bool) -> String {
        if isRenameOrCopy, let arrowRange = splitRenameArrow(in: rawPath) {
            let destination = String(rawPath[arrowRange.upperBound...])
            return unquoteCStringIfNeeded(destination)
        }
        return unquoteCStringIfNeeded(rawPath)
    }

    private static func splitRenameArrow(in rawPath: String) -> Range<String.Index>? {
        var inQuotes = false
        var escaped = false
        var index = rawPath.startIndex

        while index < rawPath.endIndex {
            let ch = rawPath[index]
            if escaped {
                escaped = false
            } else if ch == "\\" && inQuotes {
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, rawPath[index...].hasPrefix(" -> ") {
                let end = rawPath.index(index, offsetBy: 4)
                return index..<end
            }
            index = rawPath.index(after: index)
        }

        return rawPath.range(of: " -> ")
    }

    private static func parseDiffGitHeaderPath(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        // When both sides are identical (common case, even with spaces), midpoint splitting is exact.
        if rest.count >= 5 {
            let midOffset = rest.count / 2
            let midIndex = rest.index(rest.startIndex, offsetBy: midOffset)
            if rest[midIndex] == " " {
                let left = String(rest[..<midIndex])
                let right = String(rest[rest.index(after: midIndex)...])
                let unquotedLeft = stripDiffPathPrefix(left, prefix: "a/")
                let unquotedRight = stripDiffPathPrefix(right, prefix: "b/")
                if left.hasPrefix("a/") || left.hasPrefix("\"a/"),
                   right.hasPrefix("b/") || right.hasPrefix("\"b/"),
                   unquotedLeft == unquotedRight
                {
                    return unquotedRight
                }
            }
        }

        if let bRange = rest.range(of: " b/", options: .backwards) {
            return unquoteCStringIfNeeded(String(rest[bRange.upperBound...]))
        }
        if let quotedBRange = rest.range(of: " \"b/", options: .backwards) {
            let raw = "\"b/" + String(rest[quotedBRange.upperBound...])
            return stripDiffPathPrefix(raw, prefix: "b/")
        }
        return ""
    }

    private static func stripDiffPathPrefix(_ raw: String, prefix: String) -> String {
        let unquoted = unquoteCStringIfNeeded(raw)
        if unquoted.hasPrefix(prefix) {
            return String(unquoted.dropFirst(prefix.count))
        }
        return unquoted
    }

    private static func unquoteCStringIfNeeded(_ raw: String) -> String {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else {
            return raw
        }
        let chars = Array(raw.dropFirst().dropLast())
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count)

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch != "\\" {
                bytes.append(contentsOf: String(ch).utf8)
                i += 1
                continue
            }
            i += 1
            guard i < chars.count else {
                bytes.append(UInt8(ascii: "\\"))
                break
            }
            let escaped = chars[i]
            switch escaped {
            case "a": bytes.append(0x07); i += 1
            case "b": bytes.append(0x08); i += 1
            case "f": bytes.append(0x0C); i += 1
            case "n": bytes.append(UInt8(ascii: "\n")); i += 1
            case "r": bytes.append(UInt8(ascii: "\r")); i += 1
            case "t": bytes.append(UInt8(ascii: "\t")); i += 1
            case "v": bytes.append(0x0B); i += 1
            case "\\": bytes.append(UInt8(ascii: "\\")); i += 1
            case "\"": bytes.append(UInt8(ascii: "\"")); i += 1
            case "0"..."7":
                if i + 2 < chars.count,
                   let d1 = octalDigitValue(chars[i]),
                   let d2 = octalDigitValue(chars[i + 1]),
                   let d3 = octalDigitValue(chars[i + 2]),
                   case let value = (d1 << 6) | (d2 << 3) | d3,
                   value <= 0xFF
                {
                    bytes.append(UInt8(value))
                    i += 3
                } else {
                    bytes.append(contentsOf: String(escaped).utf8)
                    i += 1
                }
            default:
                bytes.append(contentsOf: String(escaped).utf8)
                i += 1
            }
        }

        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func octalDigitValue(_ ch: Character) -> Int? {
        guard let ascii = ch.asciiValue,
              ascii >= UInt8(ascii: "0"),
              ascii <= UInt8(ascii: "7")
        else {
            return nil
        }
        return Int(ascii - UInt8(ascii: "0"))
    }
}
