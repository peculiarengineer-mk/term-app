import Foundation
import CLibSSH2

/// A single entry returned by SFTP directory listing.
public struct SFTPEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: UInt64
    public let permissions: UInt32
    public let modifiedAt: Date?

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: UInt64 = 0,
        permissions: UInt32 = 0,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.permissions = permissions
        self.modifiedAt = modifiedAt
    }
}

/// Pure POSIX-style path helpers and entry sorting for SFTP paths.
public enum SFTPPath {
    /// Joins a directory path and a child entry name without duplicating slashes.
    public static func join(_ dir: String, _ name: String) -> String {
        let cleanName = name.hasPrefix("/") ? String(name.drop(while: { $0 == "/" })) : name
        if dir.isEmpty {
            return name
        }
        if cleanName.isEmpty {
            return dir
        }
        var base = dir
        while base.count > 1 && base.hasSuffix("/") {
            base.removeLast()
        }
        if base == "/" {
            return "/" + cleanName
        }
        return base + "/" + cleanName
    }

    /// Returns the parent directory of `path` using POSIX semantics.
    public static func parent(of path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        if p.isEmpty || p == "/" {
            return "/"
        }
        guard let slash = p.lastIndex(of: "/") else {
            return "."
        }
        let prefix = p[..<slash]
        if prefix.isEmpty || prefix.allSatisfy({ $0 == "/" }) {
            return "/"
        }
        return String(prefix)
    }

    /// Sorts entries with directories first, then case-insensitively by name.
    public static func sortEntries(_ entries: [SFTPEntry]) -> [SFTPEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp = lhs.name.caseInsensitiveCompare(rhs.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.path < rhs.path
        }
    }
}

/// Errors produced by SFTP operations on `SSHConnection`.
public enum SFTPError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case initFailed(String)
    case ioFailed(String)
    case fileTooLarge(Int)
    case notFound(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH connection is not connected."
        case .initFailed(let message):
            return "Failed to initialize SFTP subsystem: \(message)"
        case .ioFailed(let message):
            return message
        case .fileTooLarge(let size):
            return "File exceeds maximum allowed size (\(size) bytes)."
        case .notFound(let path):
            return "Remote path not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}

enum SFTPUtil {
    /// Normalizes shorthand roots (`""`, `"."`, `"~"`, `"~/..."`) for SFTP `realpath`.
    static func realpathInput(for path: String) -> String {
        if path.isEmpty || path == "." || path == "~" {
            return "."
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return rest.isEmpty ? "." : rest
        }
        return path
    }

    static func shouldResolveBeforeListing(_ path: String) -> Bool {
        path.isEmpty || path == "." || path == "~" || path.hasPrefix("~/")
    }

    /// Builds an `SFTPEntry` from a directory path, filename, and `LIBSSH2_SFTP_ATTRIBUTES`.
    static func makeEntry(directory: String, name: String, attrs: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPEntry {
        let hasPerms = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)) != 0
        let perms = hasPerms ? UInt32(truncatingIfNeeded: attrs.permissions) : 0
        let fileType = perms & UInt32(LIBSSH2_SFTP_S_IFMT)
        let isDirectory = hasPerms && fileType == UInt32(LIBSSH2_SFTP_S_IFDIR)
        let isSymlink = hasPerms && fileType == UInt32(LIBSSH2_SFTP_S_IFLNK)
        let size = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE)) != 0 ? UInt64(attrs.filesize) : 0
        let modifiedAt: Date? = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)) != 0
            ? Date(timeIntervalSince1970: TimeInterval(attrs.mtime))
            : nil
        return SFTPEntry(
            name: name,
            path: SFTPPath.join(directory, name),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            permissions: perms,
            modifiedAt: modifiedAt
        )
    }

    static func mapStatus(_ status: UInt, context: String) -> SFTPError {
        switch status {
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .notFound(context)
        case UInt(LIBSSH2_FX_PERMISSION_DENIED):
            return .permissionDenied(context)
        default:
            return .ioFailed("\(context) (SFTP status \(status))")
        }
    }

    static func uploadOpenFlags(exclusive: Bool) -> UInt {
        var flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        if exclusive {
            flags |= UInt(LIBSSH2_FXF_EXCL)
        }
        return flags
    }

    static func sftpLength(byteCount: Int) throws -> UInt32 {
        guard let len = UInt32(exactly: byteCount) else {
            throw SFTPError.ioFailed("Remote path exceeds maximum SFTP length")
        }
        return len
    }

    static func pathLength(_ path: String) throws -> UInt32 {
        try sftpLength(byteCount: path.utf8.count)
    }
}
