import Foundation

/// Pure byte encodings for terminal keys. Used by the extra-keys bar and covered by `KeyEncodingTests`.
public enum KeyEncoder {
    public enum Arrow: Sendable { case up, down, right, left
        var letter: UInt8 {
            switch self { case .up: 0x41; case .down: 0x42; case .right: 0x43; case .left: 0x44 }
        }
    }

    public static let escape: [UInt8] = [0x1b]
    public static let tab: [UInt8] = [0x09]

    /// Ctrl+key: letters (either case) map to 0x01…0x1A; `@ [ \ ] ^ _ ?` and space to their C0 codes.
    public static func ctrl(_ ch: Character) -> [UInt8]? {
        guard ch.isASCII, let a = ch.asciiValue else { return nil }
        switch a {
        case 0x61...0x7a: return [a - 0x60]
        case 0x40...0x5f: return [a - 0x40]
        case 0x20: return [0x00]
        case 0x3f: return [0x7f]
        default: return nil
        }
    }

    /// Alt/Meta: ESC prefix before the bytes.
    public static func meta(_ bytes: [UInt8]) -> [UInt8] { escape + bytes }

    /// Arrow key. Normal mode `ESC [ X`, application cursor mode `ESC O X`.
    /// With Ctrl (and optionally Alt) the xterm modifier form `ESC [ 1 ; m X` is used in both modes.
    /// Alt alone matches SwiftTerm 1.11.2's hardware keyboard: Left/Right send `ESC b` / `ESC f`
    /// (word motion) and Up/Down send the plain arrow (SwiftTerm ignores modifiers on Up/Down).
    /// Deliberate difference: with Ctrl the bar sends the xterm `ESC [ 1 ; m X` form for every arrow,
    /// where SwiftTerm's hardware path sends plain Up/Down and `ESC b`/`ESC f` for Ctrl+Alt+Left/Right.
    public static func arrow(_ arrow: Arrow, applicationCursor: Bool, ctrl: Bool = false, alt: Bool = false) -> [UInt8] {
        if alt && !ctrl {
            switch arrow {
            case .left: return [0x1b, 0x62]
            case .right: return [0x1b, 0x66]
            default: return [0x1b, applicationCursor ? 0x4f : 0x5b, arrow.letter]
            }
        }
        if ctrl {
            let m: UInt8 = 0x31 + (alt ? 2 : 0) + (ctrl ? 4 : 0)  // 1 + alt(2) + ctrl(4), as ASCII digit
            return [0x1b, 0x5b, 0x31, 0x3b, m, arrow.letter]
        }
        return [0x1b, applicationCursor ? 0x4f : 0x5b, arrow.letter]
    }

    /// Applies sticky modifiers to typed text (a single character gets Ctrl; Alt prefixes ESC).
    public static func text(_ s: String, ctrl: Bool = false, alt: Bool = false) -> [UInt8] {
        var bytes = Array(s.utf8)
        if ctrl, s.count == 1, let c = s.first, let b = Self.ctrl(c) { bytes = b }
        return alt ? meta(bytes) : bytes
    }
}
