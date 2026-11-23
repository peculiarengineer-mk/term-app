import SwiftUI
import UIKit
import TermUI

/// Centralized appearance preferences (`@AppStorage` / `UserDefaults`) and theme picker UI.
enum AppearanceSettings {
    static let themeKey = "terminal.theme"
    static let fontSizeKey = "terminal.fontSize"
    static let fontFamilyKey = "terminal.fontFamily"
    static let cursorStyleKey = "terminal.cursorStyle"
    static let hapticsKey = "terminal.haptics"

    static let defaultThemeName = TerminalTheme.appleProDark.name
    static let defaultFontSize: Double = 14.0
    static let minFontSize: Double = 8.0
    static let maxFontSize: Double = 32.0
    static let defaultFontFamilyRaw = TerminalFontFamily.sfMono.rawValue
    static let defaultCursorStyleRaw = TerminalCursorStyle.block.rawValue
    static let defaultHapticsEnabled = true

    static func currentTheme(defaults: UserDefaults = .standard) -> TerminalTheme {
        let name = defaults.string(forKey: themeKey) ?? defaultThemeName
        return TerminalTheme.preset(named: name)
    }

    static func currentFontFamily(defaults: UserDefaults = .standard) -> TerminalFontFamily {
        guard let raw = defaults.string(forKey: fontFamilyKey),
              let family = TerminalFontFamily(rawValue: raw) else {
            return .sfMono
        }
        return family
    }

    static func currentCursorStyle(defaults: UserDefaults = .standard) -> TerminalCursorStyle {
        guard let raw = defaults.string(forKey: cursorStyleKey),
              let style = TerminalCursorStyle(rawValue: raw) else {
            return .block
        }
        return style
    }

    static func currentFontSize(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: fontSizeKey) != nil else {
            return CGFloat(defaultFontSize)
        }
        let stored = defaults.double(forKey: fontSizeKey)
        guard stored.isFinite, stored > 0 else { return CGFloat(defaultFontSize) }
        return min(max(CGFloat(stored), CGFloat(minFontSize)), CGFloat(maxFontSize))
    }

    static func hapticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: hapticsKey) != nil else { return defaultHapticsEnabled }
        return defaults.bool(forKey: hapticsKey)
    }

    static func preferredColorScheme(for theme: TerminalTheme) -> ColorScheme {
        theme.isDark ? .dark : .light
    }

    static func formattedFontSize(_ size: Double) -> String {
        size.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(size)) pt" : String(format: "%.1f pt", size)
    }
}

struct ThemePickerView: View {
    @AppStorage(AppearanceSettings.themeKey) private var selectedThemeName = AppearanceSettings.defaultThemeName

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(TerminalTheme.allPresets, id: \.name) { theme in
                    ThemePreviewCard(theme: theme, isSelected: theme.name == selectedThemeName) {
                        AppHaptics.impact(.light)
                        selectedThemeName = theme.name
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemePreviewCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var cursorWidth: CGFloat = 7
    @ScaledMetric(relativeTo: .footnote) private var cursorHeight: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var cursorLeading: CGFloat = 3

    private static let previewPaletteIndices = [1, 2, 3, 4, 5, 6]

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(theme.name)
                        .font(.headline)
                        .foregroundStyle(theme.foregroundColor)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(Self.previewPaletteIndices, id: \.self) { index in
                            Circle()
                                .fill(theme.ansi[index].color)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryForegroundColor.opacity(0.65))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("dev@box")
                            .foregroundStyle(theme.ansi[2].color)
                        Text(" ~ ")
                            .foregroundStyle(theme.ansi[4].color)
                        Text("% ssh prod")
                            .foregroundStyle(theme.foregroundColor)
                        Rectangle()
                            .fill(theme.cursor.color)
                            .frame(width: cursorWidth, height: cursorHeight)
                            .padding(.leading, cursorLeading)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    HStack(spacing: 8) {
                        Text("kex: mlkem768")
                            .foregroundStyle(theme.ansi[6].color)
                        Text("tmux: main")
                            .foregroundStyle(theme.ansi[3].color)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .padding(14)
            .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected
                            ? theme.accentColor
                            : (theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
