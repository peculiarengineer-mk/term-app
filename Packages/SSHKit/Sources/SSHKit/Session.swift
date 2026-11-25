import Foundation

public enum SessionState: Sendable, Equatable {
    case connecting
    case awaitingHostKeyDecision(HostKey)
    case authenticating
    case connected
    case disconnected(SSHError?)
}

public protocol Session: Sendable {
    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    var output: AsyncStream<Data> { get }
    var state: AsyncStream<SessionState> { get }
    func close() async
    /// Active liveness check: false means the connection is dead (it has torn down as `.disconnected(.timeout)`).
    func probe(timeout: Duration) async -> Bool
    /// Executes a non-interactive one-shot command on a dedicated channel without disturbing the PTY stream.
    func exec(_ command: String, timeout: Duration) async throws -> SSHExecResult
}

public extension Session {
    func probe(timeout: Duration) async -> Bool { true }

    func exec(_ command: String) async throws -> SSHExecResult {
        try await exec(command, timeout: .seconds(15))
    }

    func exec(_ command: String, timeout: Duration) async throws -> SSHExecResult {
        throw SSHError.channelFailed("exec is not supported on this session")
    }
}
