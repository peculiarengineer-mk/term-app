import UIKit
import SwiftTerm

public struct TerminalTheme: Sendable {
    public struct RGB: Sendable {
        public let r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
        var uiColor: UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        var termColor: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
    }

    public let name: String
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    /// The 16 ANSI colours: 0–7 normal, 8–15 bright.
    public let ansi: [RGB]

    public init(name: String, foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB]) {
        precondition(ansi.count == 16, "a theme needs 16 ANSI colours")
        self.name = name; self.foreground = foreground; self.background = background
        self.cursor = cursor; self.ansi = ansi
    }

    public static let dark = TerminalTheme(
        name: "Dark",
        foreground: .init(0xD4, 0xD4, 0xD4), background: .init(0x1E, 0x1E, 0x1E), cursor: .init(0xAE, 0xAF, 0xAD),
        ansi: [
            .init(0x00, 0x00, 0x00), .init(0xCD, 0x31, 0x31), .init(0x0D, 0xBC, 0x79), .init(0xE5, 0xE5, 0x10),
            .init(0x24, 0x72, 0xC8), .init(0xBC, 0x3F, 0xBC), .init(0x11, 0xA8, 0xCD), .init(0xE5, 0xE5, 0xE5),
            .init(0x66, 0x66, 0x66), .init(0xF1, 0x4C, 0x4C), .init(0x23, 0xD1, 0x8B), .init(0xF5, 0xF5, 0x43),
            .init(0x3B, 0x8E, 0xEA), .init(0xD6, 0x70, 0xD6), .init(0x29, 0xB8, 0xDB), .init(0xFF, 0xFF, 0xFF),
        ])

    public static let light = TerminalTheme(
        name: "Light",
        foreground: .init(0x33, 0x33, 0x33), background: .init(0xFF, 0xFF, 0xFF), cursor: .init(0x00, 0x00, 0x00),
        ansi: [
            .init(0x00, 0x00, 0x00), .init(0xCD, 0x31, 0x31), .init(0x00, 0x80, 0x00), .init(0x94, 0x80, 0x00),
            .init(0x04, 0x51, 0xA5), .init(0xBC, 0x05, 0xBC), .init(0x05, 0x98, 0xBC), .init(0x55, 0x55, 0x55),
            .init(0x66, 0x66, 0x66), .init(0xCD, 0x31, 0x31), .init(0x14, 0xCE, 0x14), .init(0xB5, 0xBA, 0x00),
            .init(0x04, 0x51, 0xA5), .init(0xBC, 0x05, 0xBC), .init(0x05, 0x98, 0xBC), .init(0xA5, 0xA5, 0xA5),
        ])

    @MainActor func apply(to view: TerminalView) {
        view.installColors(ansi.map(\.termColor))
        view.nativeForegroundColor = foreground.uiColor
        view.nativeBackgroundColor = background.uiColor
        view.caretColor = cursor.uiColor
        view.backgroundColor = background.uiColor
    }
}
