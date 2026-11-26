import Foundation

/// High-level execution state inferred from an AI coding agent's terminal stream.
public enum AgentActivityState: Sendable, Equatable, Hashable {
    case idle
    case running
    case waitingForApproval(prompt: String?)
    case completed
}

/// Pure ANSI stripper and terminal-output heuristics for AI coding agent sessions.
public struct AgentActivityDetector: Sendable {
    private static let maxApprovalSnippetLength = 90
    private static let inspectedTrailingLines = 6

    private static let caseSensitivePromptMarkers: [String] = [
        "[y/N]",
        "[Y/n]",
        "[y/n]",
        "[Y/N]",
    ]

    private static let primaryCaseInsensitivePromptMarkers: [String] = [
        "(y/n)",
        "do you want to proceed",
        "approve?",
        "confirm?",
        "would you like to",
    ]

    private static let secondaryCaseInsensitivePromptMarkers: [String] = [
        "allow once",
        "allow always",
        "press enter to continue",
        "enter to confirm",
    ]

    public init() {}

    /// Strips ANSI CSI, OSC, DCS/PM/APC, charset escapes, and control characters except `\n` and `\t`.
    public static func stripANSI(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)

        var index = 0
        let count = scalars.count

        while index < count {
            let value = scalars[index].value

            if value == 0x1B {
                index = skipEscapeSequence(scalars, startingAt: index)
                continue
            }

            if value == 0x09 || value == 0x0A {
                output.append(scalars[index])
            } else if value >= 0x20 && value != 0x7F && !(value >= 0x80 && value <= 0x9F) {
                output.append(scalars[index])
            }

            index += 1
        }

        return String(output)
    }

    /// Inspects the trailing non-empty lines of stripped output for interactive agent/CLI approval prompts.
    public static func detectApprovalPrompt(in text: String) -> String? {
        let stripped = stripANSI(text)
        let nonEmptyLines = stripped
            .split(whereSeparator: \.isNewline)
            .map { cleanSnippetLine(String($0)) }
            .filter { !$0.isEmpty }

        guard !nonEmptyLines.isEmpty else { return nil }

        let tail = Array(nonEmptyLines.suffix(inspectedTrailingLines))
        for line in tail.reversed() where matchesPrimaryApprovalPattern(line) {
            return truncateSnippet(line, limit: maxApprovalSnippetLength)
        }
        for line in tail.reversed() where matchesSecondaryApprovalPattern(line) {
            return truncateSnippet(line, limit: maxApprovalSnippetLength)
        }
        return nil
    }

    /// Counts visible alphanumeric characters after stripping ANSI escapes and terminal chrome/spinner glyphs.
    public static func meaningfulCharacterCount(_ chunk: String) -> Int {
        let stripped = stripANSI(chunk)
        guard !stripped.isEmpty else { return 0 }

        var count = 0
        for character in stripped {
            if character.unicodeScalars.contains(where: isIgnoredChromeScalar) {
                continue
            }
            if character.isLetter || character.isNumber {
                count += 1
            }
        }
        return count
    }

    /// Returns `true` when `chunk` contains at least two meaningful alphanumeric characters after stripping ANSI and chrome glyphs.
    public static func isMeaningfulOutput(_ chunk: String) -> Bool {
        meaningfulCharacterCount(chunk) >= 2
    }

    // MARK: - Private Helpers

    private static func skipEscapeSequence(_ scalars: [UnicodeScalar], startingAt escIndex: Int) -> Int {
        let count = scalars.count
        let nextIndex = escIndex + 1
        guard nextIndex < count else { return count }

        let introducer = scalars[nextIndex].value

        switch introducer {
        case 0x5B: // CSI: ESC [
            var idx = nextIndex + 1
            while idx < count, scalars[idx].value >= 0x30 && scalars[idx].value <= 0x3F {
                idx += 1
            }
            while idx < count, scalars[idx].value >= 0x20 && scalars[idx].value <= 0x2F {
                idx += 1
            }
            if idx < count, scalars[idx].value >= 0x40 && scalars[idx].value <= 0x7E {
                idx += 1
            }
            return idx

        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // OSC / DCS / SOS / PM / APC
            return skipStringTerminatedSequence(scalars, startingAt: nextIndex + 1)

        case 0x20...0x2F: // nF sequence (e.g. ESC ( B)
            var idx = nextIndex + 1
            while idx < count, scalars[idx].value >= 0x20 && scalars[idx].value <= 0x2F {
                idx += 1
            }
            if idx < count, scalars[idx].value >= 0x30 && scalars[idx].value <= 0x7E {
                idx += 1
            }
            return idx

        case 0x30...0x7E: // 2-byte escape sequence
            return nextIndex + 1

        default:
            return nextIndex
        }
    }

    private static func skipStringTerminatedSequence(_ scalars: [UnicodeScalar], startingAt startIndex: Int) -> Int {
        let count = scalars.count
        var idx = startIndex
        while idx < count {
            let value = scalars[idx].value
            if value == 0x07 || value == 0x9C {
                return idx + 1
            }
            if value == 0x1B && idx + 1 < count && scalars[idx + 1].value == 0x5C {
                return idx + 2
            }
            idx += 1
        }
        return count
    }

    private static func matchesPrimaryApprovalPattern(_ line: String) -> Bool {
        if caseSensitivePromptMarkers.contains(where: { line.contains($0) }) {
            return true
        }
        let lowercased = line.lowercased()
        return primaryCaseInsensitivePromptMarkers.contains(where: { lowercased.contains($0) })
    }

    private static func matchesSecondaryApprovalPattern(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return secondaryCaseInsensitivePromptMarkers.contains(where: { lowercased.contains($0) })
    }

    private static func cleanSnippetLine(_ raw: String) -> String {
        let borderChars = CharacterSet(charactersIn: "│┃┌┐└┘├┤╭╮╰╯─━ ")
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: borderChars)
    }

    private static func isIgnoredChromeScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x259F, // Box Drawing & Block Elements
             0x25A0...0x25FF, // Geometric Shapes (e.g. ◐◓◑◒)
             0x2700...0x27BF, // Dingbats (e.g. ✶✸✹✺✻✽✳✢, ✓, dingbat numbers)
             0x2800...0x28FF, // Braille Patterns (e.g. ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
             0x00B7,          // Middle dot (·)
             0x2022,          // Bullet (•)
             0x2026:          // Horizontal ellipsis (…)
            return true
        default:
            return false
        }
    }

    private static func truncateSnippet(_ line: String, limit: Int) -> String {
        guard line.count > limit else { return line }
        let prefixCount = max(1, limit - 1)
        return String(line.prefix(prefixCount)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
