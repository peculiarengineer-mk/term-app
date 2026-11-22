import Foundation

/// Transport-agnostic byte pipe between the terminal view and whatever backs it (SSH, mosh, a test double).
/// TermUI depends only on this protocol, never on SSH.
public protocol TerminalIO: AnyObject, Sendable {
    /// Bytes typed by the user, to be sent to the remote side.
    func send(_ bytes: [UInt8])
    /// The terminal grid changed size.
    func resized(cols: Int, rows: Int)
    /// Bytes from the remote side, to be rendered. The view consumes this stream once.
    var incoming: AsyncStream<Data> { get }
    /// Like `incoming`, but with recent output already seen by an earlier view split out as `replay`.
    /// The view renders `replay` without answering terminal queries in it (they were answered already).
    func subscribe() -> (replay: Data, live: AsyncStream<Data>)
}

public extension TerminalIO {
    /// Default for backends without a replay buffer.
    func subscribe() -> (replay: Data, live: AsyncStream<Data>) { (Data(), incoming) }
}
