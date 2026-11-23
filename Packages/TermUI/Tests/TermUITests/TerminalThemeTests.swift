import XCTest
import SwiftUI
@testable import TermUI

final class TerminalThemeTests: XCTestCase {
    func testAllPresetsAndPaletteIntegrity() {
        XCTAssertEqual(TerminalTheme.allPresets.count, 7)
        let expectedNames = [
            "Apple Pro Dark",
            "Ghostty Dark",
            "Tokyo Night",
            "Catppuccin Mocha",
            "Nord",
            "Solarized Dark",
            "Light",
        ]
        XCTAssertEqual(TerminalTheme.allPresets.map(\.name), expectedNames)
        XCTAssertEqual(TerminalTheme.allPresets.first, .appleProDark)

        for theme in TerminalTheme.allPresets + [.dark, .light] {
            XCTAssertEqual(theme.ansi.count, 16, "\(theme.name) must have 16 ANSI colours")
            _ = theme.foreground.uiColor
            _ = theme.foreground.color
            _ = theme.backgroundColor
            _ = theme.foregroundColor
            _ = theme.accentColor
        }
    }

    func testIsDarkFlag() {
        XCTAssertTrue(TerminalTheme.appleProDark.isDark)
        XCTAssertTrue(TerminalTheme.ghosttyDark.isDark)
        XCTAssertTrue(TerminalTheme.tokyoNight.isDark)
        XCTAssertTrue(TerminalTheme.catppuccinMocha.isDark)
        XCTAssertTrue(TerminalTheme.nord.isDark)
        XCTAssertTrue(TerminalTheme.solarizedDark.isDark)
        XCTAssertTrue(TerminalTheme.dark.isDark)
        XCTAssertFalse(TerminalTheme.light.isDark)
    }

    func testPresetLookupAndFallbacks() {
        for preset in TerminalTheme.allPresets {
            XCTAssertEqual(TerminalTheme.preset(named: preset.name), preset)
        }
        XCTAssertEqual(TerminalTheme.preset(named: "Dark"), .dark)
        XCTAssertEqual(TerminalTheme.preset(named: "Ghostty Dark"), .ghosttyDark)
        XCTAssertEqual(TerminalTheme.preset(named: "unknown"), .appleProDark)
        XCTAssertEqual(TerminalTheme.preset(named: "Nonexistent Theme"), .appleProDark)
        XCTAssertEqual(TerminalTheme.preset(named: ""), .appleProDark)
    }

    func testPresetColorsMatchCanonicalHexValues() {
        XCTAssertEqual(TerminalTheme.appleProDark.background, .init(0x12, 0x13, 0x18))
        XCTAssertEqual(TerminalTheme.appleProDark.foreground, .init(0xF2, 0xF2, 0xF7))
        XCTAssertEqual(TerminalTheme.appleProDark.cursor, .init(0xFF, 0x9F, 0x0A))
        XCTAssertEqual(TerminalTheme.appleProDark.accent, .init(0xFF, 0x9F, 0x0A))
        XCTAssertEqual(TerminalTheme.appleProDark.ansi[4], .init(0x0A, 0x84, 0xFF))
        XCTAssertEqual(TerminalTheme.appleProDark.accentColor, TerminalTheme.RGB(0xFF, 0x9F, 0x0A).color)
        XCTAssertEqual(TerminalTheme.appleProDark.accentUIColor, TerminalTheme.RGB(0xFF, 0x9F, 0x0A).uiColor)

        XCTAssertEqual(TerminalTheme.tokyoNight.background, .init(0x1A, 0x1B, 0x26))
        XCTAssertEqual(TerminalTheme.tokyoNight.foreground, .init(0xC0, 0xCA, 0xF5))
        XCTAssertEqual(TerminalTheme.catppuccinMocha.background, .init(0x1E, 0x1E, 0x2E))
        XCTAssertEqual(TerminalTheme.catppuccinMocha.foreground, .init(0xCD, 0xD6, 0xF4))
        XCTAssertEqual(TerminalTheme.nord.background, .init(0x2E, 0x34, 0x40))
        XCTAssertEqual(TerminalTheme.nord.foreground, .init(0xD8, 0xDE, 0xE9))
        XCTAssertEqual(TerminalTheme.solarizedDark.background, .init(0x00, 0x2B, 0x36))
        XCTAssertEqual(TerminalTheme.solarizedDark.foreground, .init(0x83, 0x94, 0x96))
        XCTAssertEqual(TerminalTheme.ghosttyDark.foreground, .init(0xE6, 0xE8, 0xEE))
    }

    func testCustomAccentOverridesDefaultAnsiBlue() {
        let customAccent = TerminalTheme.RGB(0xFF, 0x37, 0x5F)
        let custom = TerminalTheme(
            name: "Custom",
            foreground: TerminalTheme.dark.foreground,
            background: TerminalTheme.dark.background,
            cursor: TerminalTheme.dark.cursor,
            ansi: TerminalTheme.dark.ansi,
            accent: customAccent
        )
        let fallback = TerminalTheme(
            name: "Custom",
            foreground: TerminalTheme.dark.foreground,
            background: TerminalTheme.dark.background,
            cursor: TerminalTheme.dark.cursor,
            ansi: TerminalTheme.dark.ansi
        )

        XCTAssertEqual(custom.accent, customAccent)
        XCTAssertEqual(custom.accentColor, customAccent.color)
        XCTAssertEqual(custom.accentUIColor, customAccent.uiColor)
        XCTAssertNil(fallback.accent)
        XCTAssertEqual(fallback.accentColor, TerminalTheme.dark.ansi[4].color)
        XCTAssertNotEqual(custom, fallback)
    }

    func testSecondaryForegroundMeetsWCAGContrastAcrossAllPresets() {
        for theme in TerminalTheme.allPresets + [.dark] {
            _ = theme.secondaryForegroundColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(
                theme.secondaryForegroundUIColor.getRed(&r, green: &g, blue: &b, alpha: &a),
                "\(theme.name) secondaryForegroundUIColor should convert to sRGB"
            )
            let secondary = TerminalTheme.RGB(
                UInt8((r * 255).rounded()),
                UInt8((g * 255).rounded()),
                UInt8((b * 255).rounded())
            )
            let ratio = secondary.contrastRatio(with: theme.background)
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "\(theme.name) secondaryForeground contrast \(ratio) must be >= 4.5:1"
            )
        }

        // Solarized Dark full foreground is ~4.75:1, so secondary stays >= 4.5:1 instead of fading too far.
        XCTAssertEqual(TerminalTheme.solarizedDark.secondaryForegroundUIColor, TerminalTheme.solarizedDark.foreground.uiColor)
        // High-contrast themes get a genuinely muted secondary shade.
        XCTAssertNotEqual(TerminalTheme.appleProDark.secondaryForegroundUIColor, TerminalTheme.appleProDark.foreground.uiColor)
        XCTAssertNotEqual(TerminalTheme.ghosttyDark.secondaryForegroundUIColor, TerminalTheme.ghosttyDark.foreground.uiColor)
    }
}
