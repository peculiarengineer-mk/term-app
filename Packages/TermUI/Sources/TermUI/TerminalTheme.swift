import UIKit
import SwiftUI
import SwiftTerm

public struct TerminalTheme: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public let r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
        fileprivate init(hex: UInt32) {
            self.r = UInt8((hex >> 16) & 0xFF)
            self.g = UInt8((hex >> 8) & 0xFF)
            self.b = UInt8(hex & 0xFF)
        }
        public var uiColor: UIColor {
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        public var color: SwiftUI.Color {
            SwiftUI.Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
        var termColor: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }

        /// Relative sRGB luminance in `0...1` per WCAG 2.1.
        public var relativeLuminance: Double {
            func linear(_ channel: UInt8) -> Double {
                let c = Double(channel) / 255.0
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG 2.1 contrast ratio (`1.0...21.0`) against `other`.
        public func contrastRatio(with other: RGB) -> Double {
            let l1 = relativeLuminance
            let l2 = other.relativeLuminance
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }

        fileprivate func blendedRGB(with other: RGB, fraction: Double) -> RGB {
            let t = min(max(fraction, 0), 1)
            let nr = UInt8((Double(r) * (1 - t) + Double(other.r) * t).rounded())
            let ng = UInt8((Double(g) * (1 - t) + Double(other.g) * t).rounded())
            let nb = UInt8((Double(b) * (1 - t) + Double(other.b) * t).rounded())
            return RGB(nr, ng, nb)
        }

        fileprivate func blended(with other: RGB, fraction: Double) -> UIColor {
            let t = min(max(fraction, 0), 1)
            let nr = (Double(r) * (1 - t) + Double(other.r) * t) / 255.0
            let ng = (Double(g) * (1 - t) + Double(other.g) * t) / 255.0
            let nb = (Double(b) * (1 - t) + Double(other.b) * t) / 255.0
            return UIColor(red: nr, green: ng, blue: nb, alpha: 1)
        }
    }

    public let name: String
    public let foreground: RGB
    public let background: RGB
    public let cursor: RGB
    /// The 16 ANSI colours: 0–7 normal, 8–15 bright.
    public let ansi: [RGB]
    public let accent: RGB?

    public init(name: String, foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB], accent: RGB? = nil) {
        precondition(ansi.count == 16, "a theme needs 16 ANSI colours")
        self.name = name; self.foreground = foreground; self.background = background
        self.cursor = cursor; self.ansi = ansi; self.accent = accent
    }

    public var backgroundColor: SwiftUI.Color { background.color }
    public var foregroundColor: SwiftUI.Color { foreground.color }
    /// Secondary foreground colour blended toward `background` while guaranteeing ≥ 4.5:1 WCAG AA contrast
    /// (falling back to `foreground` when blending would drop below 4.5:1, e.g. Solarized Dark).
    public var secondaryForegroundColor: SwiftUI.Color { secondaryForegroundRGB.color }
    public var secondaryForegroundUIColor: UIColor { secondaryForegroundRGB.uiColor }
    public var accentColor: SwiftUI.Color { accentRGB.color }
    public var isDark: Bool { background.relativeLuminance < 0.5 }

    private var secondaryForegroundRGB: RGB {
        let targetFraction = 0.28
        let candidate = foreground.blendedRGB(with: background, fraction: targetFraction)
        if candidate.contrastRatio(with: background) >= 4.5 {
            return candidate
        }
        guard foreground.contrastRatio(with: background) >= 4.5 else {
            return foreground
        }
        var low = 0.0
        var high = targetFraction
        var best: RGB?
        for _ in 0..<12 {
            let mid = (low + high) * 0.5
            let probe = foreground.blendedRGB(with: background, fraction: mid)
            if probe.contrastRatio(with: background) >= 4.5 {
                best = probe
                low = mid
            } else {
                high = mid
            }
        }
        if low >= 0.05, let best {
            return best
        }
        return foreground
    }

    /// Explicit theme accent if provided; otherwise ANSI normal blue (`ansi[4]`), which stays vivid across all palettes, including Solarized where bright blue (`ansi[12]`) is gray.
    private var accentRGB: RGB { accent ?? ansi[4] }
    var accentUIColor: UIColor { accentRGB.uiColor }
    var accentForegroundUIColor: UIColor {
        let lAccent = accentRGB.relativeLuminance
        let whiteContrast = (1.0 + 0.05) / (lAccent + 0.05)
        let darkBase = RGB(hex: 0x0D1117)
        let darkContrast = (lAccent + 0.05) / (darkBase.relativeLuminance + 0.05)
        return whiteContrast >= darkContrast ? .white : darkBase.uiColor
    }

    func elevatedSurfaceUIColor(highlighted: Bool = false) -> UIColor {
        if isDark {
            return background.blended(with: RGB(0xFF, 0xFF, 0xFF), fraction: highlighted ? 0.22 : 0.11)
        }
        return background.blended(with: RGB(0x00, 0x00, 0x00), fraction: highlighted ? 0.15 : 0.07)
    }

    var hairlineDividerUIColor: UIColor {
        isDark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.12)
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

    public static let appleProDark = TerminalTheme(
        name: "Apple Pro Dark",
        foreground: .init(hex: 0xF2F2F7), background: .init(hex: 0x121318), cursor: .init(hex: 0xFF9F0A),
        ansi: [
            .init(hex: 0x1C1E26), .init(hex: 0xFF453A), .init(hex: 0x30D158), .init(hex: 0xFFD60A),
            .init(hex: 0x0A84FF), .init(hex: 0xBF5AF2), .init(hex: 0x64D2FF), .init(hex: 0xE5E5EA),
            .init(hex: 0x636366), .init(hex: 0xFF6961), .init(hex: 0x4ADE80), .init(hex: 0xFFE566),
            .init(hex: 0x409CFF), .init(hex: 0xDA8FFF), .init(hex: 0x70D7FF), .init(hex: 0xFFFFFF),
        ],
        accent: .init(hex: 0xFF9F0A))

    public static let ghosttyDark = TerminalTheme(
        name: "Ghostty Dark",
        foreground: .init(hex: 0xE6E8EE), background: .init(hex: 0x14151A), cursor: .init(hex: 0xE6E8EE),
        ansi: [
            .init(hex: 0x1D1F27), .init(hex: 0xF35B6E), .init(hex: 0x4ADE80), .init(hex: 0xFBBF24),
            .init(hex: 0x4C9AFF), .init(hex: 0xC084FC), .init(hex: 0x38BDF8), .init(hex: 0xD1D5DB),
            .init(hex: 0x5C6370), .init(hex: 0xFF7A8A), .init(hex: 0x6EE7A0), .init(hex: 0xFDE047),
            .init(hex: 0x7AB8FF), .init(hex: 0xD8A8FF), .init(hex: 0x67E8F9), .init(hex: 0xF8FAFC),
        ])

    public static let tokyoNight = TerminalTheme(
        name: "Tokyo Night",
        foreground: .init(hex: 0xC0CAF5), background: .init(hex: 0x1A1B26), cursor: .init(hex: 0xC0CAF5),
        ansi: [
            .init(hex: 0x15161E), .init(hex: 0xF7768E), .init(hex: 0x9ECE6A), .init(hex: 0xE0AF68),
            .init(hex: 0x7AA2F7), .init(hex: 0xBB9AF7), .init(hex: 0x7DCFFF), .init(hex: 0xA9B1D6),
            .init(hex: 0x414868), .init(hex: 0xF7768E), .init(hex: 0x9ECE6A), .init(hex: 0xE0AF68),
            .init(hex: 0x7AA2F7), .init(hex: 0xBB9AF7), .init(hex: 0x7DCFFF), .init(hex: 0xC0CAF5),
        ])

    public static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha",
        foreground: .init(hex: 0xCDD6F4), background: .init(hex: 0x1E1E2E), cursor: .init(hex: 0xF5E0DC),
        ansi: [
            .init(hex: 0x45475A), .init(hex: 0xF38BA8), .init(hex: 0xA6E3A1), .init(hex: 0xF9E2AF),
            .init(hex: 0x89B4FA), .init(hex: 0xF5C2E7), .init(hex: 0x94E2D5), .init(hex: 0xA6ADC8),
            .init(hex: 0x585B70), .init(hex: 0xF38BA8), .init(hex: 0xA6E3A1), .init(hex: 0xF9E2AF),
            .init(hex: 0x89B4FA), .init(hex: 0xF5C2E7), .init(hex: 0x94E2D5), .init(hex: 0xBAC2DE),
        ])

    public static let nord = TerminalTheme(
        name: "Nord",
        foreground: .init(hex: 0xD8DEE9), background: .init(hex: 0x2E3440), cursor: .init(hex: 0xD8DEE9),
        ansi: [
            .init(hex: 0x3B4252), .init(hex: 0xBF616A), .init(hex: 0xA3BE8C), .init(hex: 0xEBCB8B),
            .init(hex: 0x81A1C1), .init(hex: 0xB48EAD), .init(hex: 0x88C0D0), .init(hex: 0xE5E9F0),
            .init(hex: 0x4C566A), .init(hex: 0xBF616A), .init(hex: 0xA3BE8C), .init(hex: 0xEBCB8B),
            .init(hex: 0x81A1C1), .init(hex: 0xB48EAD), .init(hex: 0x8FBCBB), .init(hex: 0xECEFF4),
        ])

    public static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        foreground: .init(hex: 0x839496), background: .init(hex: 0x002B36), cursor: .init(hex: 0x93A1A1),
        ansi: [
            .init(hex: 0x073642), .init(hex: 0xDC322F), .init(hex: 0x859900), .init(hex: 0xB58900),
            .init(hex: 0x268BD2), .init(hex: 0xD33682), .init(hex: 0x2AA198), .init(hex: 0xEEE8D5),
            .init(hex: 0x002B36), .init(hex: 0xCB4B16), .init(hex: 0x586E75), .init(hex: 0x657B83),
            .init(hex: 0x839496), .init(hex: 0x6C71C4), .init(hex: 0x93A1A1), .init(hex: 0xFDF6E3),
        ])

    public static let allPresets: [TerminalTheme] = [
        .appleProDark,
        .ghosttyDark,
        .tokyoNight,
        .catppuccinMocha,
        .nord,
        .solarizedDark,
        .light,
    ]

    public static func preset(named name: String) -> TerminalTheme {
        if let match = allPresets.first(where: { $0.name == name }) {
            return match
        }
        if name == dark.name {
            return .dark
        }
        return .appleProDark
    }

    @MainActor func apply(to view: TerminalView) {
        view.installColors(ansi.map(\.termColor))
        view.nativeForegroundColor = foreground.uiColor
        view.nativeBackgroundColor = background.uiColor
        view.caretColor = cursor.uiColor
        view.backgroundColor = background.uiColor
    }
}
