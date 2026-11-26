import Foundation
import os
import SSHKit
import TermUI

/// Adapts an SSHKit `Session` to `TerminalIO`, keeping TermUI free of any SSH dependency.
/// Writes are serialised through one stream so typed bytes keep their order.
final class SessionBridge: TerminalIO {
    private let session: any Session
    private let outbound: AsyncStream<OutboundEvent>.Continuation
    private let pump: Task<Void, Never>
    private let drain: Task<Void, Never>
    private let state = OSAllocatedUnfairLock(initialState: Fanout())

    /// Replay keeps at least this much recent output; compaction runs at 2x, so up to about 1 MB is held.
    static let replayLimit = 512 * 1024

    /// Recent output plus live subscribers; all access is under `state`.
    private struct Fanout: Sendable {
        var buffer = Data()
        var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
        var finished = false
        /// Whether the remote is on the alternate screen (vim, htop, tmux), tracked so a trimmed
        /// replay that lost the switch-in sequence still renders on the right screen.
        var altScreen = false
        var onOutputChunk: (@Sendable ([UInt8]) -> Void)?
        var onUserInput: (@Sendable ([UInt8]) -> Void)?

        private static let altOn = ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"].map { Data($0.utf8) }
        private static let altOff = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l", "\u{1b}c"].map { Data($0.utf8) }  // ESC c = reset

        mutating func append(_ data: Data) {
            // Last switch in this chunk wins (a sequence split across chunks is missed; acceptable).
            let on = Self.altOn.compactMap { data.range(of: $0, options: .backwards)?.lowerBound }.max()
            let off = Self.altOff.compactMap { data.range(of: $0, options: .backwards)?.lowerBound }.max()
            if let on, on > (off ?? -1) { altScreen = true } else if off != nil { altScreen = false }

            buffer.append(data)
            // Compact only past 2x the limit: `removeFirst` on Data keeps the old storage, so copy instead.
            if buffer.count > 2 * SessionBridge.replayLimit {
                var tail = buffer.suffix(SessionBridge.replayLimit)
                // Start the replay at a line boundary, else at an escape, else at a UTF-8 lead byte,
                // so it never begins mid escape sequence or mid character.
                if let nl = tail.firstIndex(of: 0x0A), tail.index(after: nl) < tail.endIndex {
                    tail = tail[tail.index(after: nl)...]
                } else if let esc = tail.firstIndex(of: 0x1B) {
                    tail = tail[esc...]
                } else if let lead = tail.firstIndex(where: { $0 & 0xC0 != 0x80 }) {
                    tail = tail[lead...]
                }
                buffer = Data(tail)
            }
        }

        func replay() -> Data {
            guard !buffer.isEmpty else { return buffer }
            guard altScreen, !Self.altOn.contains(where: { buffer.range(of: $0) != nil }) else { return buffer }
            return Data("\u{1b}[?1049h".utf8) + buffer
        }
    }

    private enum OutboundEvent: Sendable {
        case bytes(Data)
        case resize(cols: Int, rows: Int)
    }

    var onOutputChunk: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onOutputChunk } }
        set { state.withLock { $0.onOutputChunk = newValue } }
    }

    var onUserInput: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onUserInput } }
        set { state.withLock { $0.onUserInput = newValue } }
    }

    /// Each access returns a fresh stream: replay of recent output, then live output.
    /// Cancelling a stream only detaches that subscriber; the session output keeps draining.
    var incoming: AsyncStream<Data> {
        let (replay, live) = subscribe()
        guard !replay.isEmpty else { return live }
        return AsyncStream { continuation in
            continuation.yield(replay)
            let task = Task {
                for await chunk in live { continuation.yield(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Replay (recent output, already answered by an earlier view) and a live stream, split so the
    /// view can feed the replay without re-answering terminal queries in it.
    func subscribe() -> (replay: Data, live: AsyncStream<Data>) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let replay: Data = state.withLock { f in
            if !f.finished { f.subscribers[id] = continuation }
            return f.replay()
        }
        // `finish()` runs `onTermination` synchronously, which takes the lock: never call it while holding it.
        if state.withLock({ $0.finished && $0.subscribers[id] == nil }) { continuation.finish() }
        continuation.onTermination = { [state] _ in
            state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return (replay, stream)
    }

    init(session: any Session) {
        self.session = session
        let (stream, continuation) = AsyncStream<OutboundEvent>.makeStream()
        self.outbound = continuation
        let state = self.state
        let output = session.output
        self.drain = Task {
            for await data in output {
                let outputObserver = state.withLock { f -> (@Sendable ([UInt8]) -> Void)? in
                    f.append(data)
                    for c in f.subscribers.values { c.yield(data) }
                    return f.onOutputChunk
                }
                if let outputObserver {
                    outputObserver(Array(data))
                }
            }
            // Detach under the lock, finish outside it (finish re-enters the lock via onTermination).
            let ending: [AsyncStream<Data>.Continuation] = state.withLock { f in
                f.finished = true
                let all = Array(f.subscribers.values)
                f.subscribers.removeAll()
                return all
            }
            for c in ending { c.finish() }
        }
        self.pump = Task {
            for await event in stream {
                switch event {
                case .bytes(let data): try? await session.write(data)
                case .resize(let cols, let rows): try? await session.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    deinit {
        outbound.finish()
        pump.cancel()
        drain.cancel()
    }

    func send(_ bytes: [UInt8]) {
        outbound.yield(.bytes(Data(bytes)))
        let inputObserver = state.withLock { $0.onUserInput }
        inputObserver?(bytes)
    }
    func resized(cols: Int, rows: Int) { outbound.yield(.resize(cols: cols, rows: rows)) }
}
