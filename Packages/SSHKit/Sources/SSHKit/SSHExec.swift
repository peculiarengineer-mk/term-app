import Foundation

/// The captured output and exit status of a one-shot remote `exec` command.
public struct SSHExecResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Convenience helpers for running one-shot SSH `exec` commands.
public enum SSHExec {
    public static let defaultTimeout: Duration = .seconds(15)
    /// Caps combined stdout + stderr memory per command execution (1 MiB).
    public static let defaultMaxOutputBytes = 1024 * 1024

    /// Connects an ephemeral `SSHConnection`, executes `command`, and cleanly closes the connection
    /// before returning or throwing.
    ///
    /// Never pops interactive UI or consumes `SSHConnection.state`; callers provide `verifyHostKey`
    /// matching `SSHConnection.connect(verifyHostKey:)`.
    public static func runCommand(
        host: String,
        port: UInt16 = 22,
        username: String,
        auth: SSHAuth,
        command: String,
        timeout: Duration = defaultTimeout,
        verifyHostKey: @escaping @Sendable (HostKey) async -> HostKeyDecision
    ) async throws -> SSHExecResult {
        try Task.checkCancellation()
        guard timeout > .zero else {
            throw SSHError.timeout
        }

        let deadline = ContinuousClock.now + timeout
        let conn = SSHConnection(host: host, port: port, username: username, auth: auth)

        do {
            let result = try await withThrowingTaskGroup(of: SSHExecResult.self) { group in
                group.addTask {
                    try await conn.connectForExec(verifyHostKey: verifyHostKey, deadline: deadline)
                    let remaining = deadline - ContinuousClock.now
                    guard remaining > .zero else {
                        throw SSHError.timeout
                    }
                    return try await conn.exec(command, timeout: remaining)
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw SSHError.timeout
                }
                guard let first = try await group.next() else {
                    throw SSHError.closed
                }
                group.cancelAll()
                return first
            }
            await conn.close()
            return result
        } catch {
            await conn.close()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

/// Bounded accumulator for stdout and stderr byte streams from a single `exec` channel.
struct SSHExecOutputAccumulator {
    let maxBytes: Int
    private(set) var stdoutData = Data()
    private(set) var stderrData = Data()

    var totalBytes: Int { stdoutData.count + stderrData.count }

    init(maxBytes: Int = SSHExec.defaultMaxOutputBytes) {
        self.maxBytes = max(0, maxBytes)
    }

    mutating func appendStdout<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
        try checkCapacity(adding: bytes.count)
        stdoutData.append(contentsOf: bytes)
    }

    mutating func appendStderr<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
        try checkCapacity(adding: bytes.count)
        stderrData.append(contentsOf: bytes)
    }

    func buildResult(exitCode: Int32) -> SSHExecResult {
        SSHExecResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: exitCode
        )
    }

    private func checkCapacity(adding count: Int) throws {
        guard count > 0 else { return }
        if count > maxBytes - totalBytes {
            throw SSHError.channelFailed("exec output exceeded \(maxBytes) byte limit")
        }
    }
}

enum SSHExecSignal {
    private static let posixNumbers: [String: Int32] = [
        "HUP": 1,
        "INT": 2,
        "QUIT": 3,
        "ILL": 4,
        "TRAP": 5,
        "ABRT": 6,
        "FPE": 8,
        "KILL": 9,
        "BUS": 10,
        "SEGV": 11,
        "SYS": 12,
        "PIPE": 13,
        "ALRM": 14,
        "TERM": 15,
    ]

    /// Maps an RFC 4254 exit signal name (e.g. `"TERM"`, `"SIGKILL"`) to a shell-style `128 + signal` exit code,
    /// or `-1` if unrecognized.
    static func exitCode(forSignalName raw: String) -> Int32 {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.hasPrefix("SIG") {
            normalized.removeFirst(3)
        }
        guard let sig = posixNumbers[normalized] else {
            return -1
        }
        return 128 + sig
    }
}
