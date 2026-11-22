import CLibSSH2

public enum SSHKit {
    /// The linked libssh2 version string, e.g. "1.11.1".
    public static func libraryVersion() -> String {
        guard let p = libssh2_version(0) else { return "" }
        return String(cString: p)
    }
}
