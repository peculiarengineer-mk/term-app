import Foundation

/// Safe remote SFTP attachment path builder and prompt insertion formatter.
public enum RemoteAttachmentHelper {
    private static let defaultDirectory = "/tmp"
    private static let defaultExtension = "png"
    private static let maxExtensionLength = 8

    /// Produces a shell-safe remote path `<directory>/termapp-attach-<16hex>.<ext>` with sanitized extension and directory.
    public static func remotePath(
        filename: String,
        id: UUID = UUID(),
        directory: String = "/tmp"
    ) -> String {
        let cleanDir = sanitizeDirectory(directory)
        let shortHex = String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        let ext = sanitizeExtension(from: filename)
        let leaf = "termapp-attach-\(shortHex).\(ext)"

        if cleanDir == "/" {
            return "/\(leaf)"
        }
        return "\(cleanDir)/\(leaf)"
    }

    /// Appends `path` to `existingPrompt` with a single separating space when needed.
    public static func promptInsertion(forRemotePath path: String, existingPrompt: String) -> String {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPath.isEmpty else { return existingPrompt }

        if existingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanPath
        }
        if let last = existingPrompt.last, last.isWhitespace {
            return existingPrompt + cleanPath
        }
        return "\(existingPrompt) \(cleanPath)"
    }

    // MARK: - Private Sanitizers

    private static func sanitizeExtension(from filename: String) -> String {
        let pathSegments = filename
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        guard let basename = pathSegments.last, !basename.isEmpty else {
            return defaultExtension
        }
        guard let dotIndex = basename.lastIndex(of: "."), dotIndex > basename.startIndex else {
            return defaultExtension
        }

        let rawExt = basename[basename.index(after: dotIndex)...]
        var filtered = ""
        filtered.reserveCapacity(min(rawExt.count, maxExtensionLength))

        for scalar in rawExt.unicodeScalars {
            let v = scalar.value
            let isLower = v >= 97 && v <= 122
            let isUpper = v >= 65 && v <= 90
            let isDigit = v >= 48 && v <= 57
            if isLower || isUpper || isDigit {
                filtered.unicodeScalars.append(scalar)
                if filtered.count >= maxExtensionLength {
                    break
                }
            }
        }

        let lowered = filtered.lowercased()
        return lowered.isEmpty ? defaultExtension : lowered
    }

    private static func sanitizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDirectory }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let isAbsolute = normalized.hasPrefix("/")
        let rawSegments = normalized.split(separator: "/").map(String.init)

        if rawSegments.contains("..") {
            return defaultDirectory
        }

        let sanitizedSegments: [String] = rawSegments.compactMap { segment in
            if segment == "." { return nil }
            let safe = sanitizeDirectorySegment(segment)
            return safe.isEmpty || safe == "." || safe == ".." ? nil : safe
        }

        if sanitizedSegments.isEmpty {
            return isAbsolute ? "/" : defaultDirectory
        }

        let joined = sanitizedSegments.joined(separator: "/")
        return isAbsolute ? "/\(joined)" : joined
    }

    private static func sanitizeDirectorySegment(_ segment: String) -> String {
        var result = ""
        result.reserveCapacity(segment.count)
        for scalar in segment.unicodeScalars {
            let v = scalar.value
            let isSafe = (v >= 97 && v <= 122)
                || (v >= 65 && v <= 90)
                || (v >= 48 && v <= 57)
                || v == 46 // .
                || v == 45 // -
                || v == 95 // _
            if isSafe {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
