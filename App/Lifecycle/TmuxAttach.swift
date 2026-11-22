import Foundation

/// Starts or re-attaches the host's tmux session after a (re)connect.
@MainActor
enum TmuxAttach {
    static let defaultCommand = "tmux new -A -s main"

    /// The line to type, or nil when the host has no tmux command. A blank command means the default.
    static func line(for command: String?) -> String? {
        guard let command else { return nil }
        let t = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultCommand : t
    }

    static func send(_ command: String?, via bridge: SessionBridge) {
        guard let line = line(for: command) else { return }
        bridge.send(Array((line + "\r").utf8))
    }
}
