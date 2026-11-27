import SwiftUI
import TermUI

/// Unified Apple Pro Instrument design system tokens, icons, cards, and adaptive layouts.
enum ProDesign {
    /// Theme-derived palette providing WCAG AA-safe semantic colors and surface tokens for dark and light themes.
    struct Palette: Sendable {
        let isDark: Bool
        let accent: Color
        let proBrandAmber: Color
        let healthy: Color
        let warning: Color
        let critical: Color
        let running: Color
        let neutral: Color
        let cardFill: Color
        let inputFill: Color
        let borderSubtle: Color
        let borderFocus: Color
        let hairline: Color

        init(theme: TerminalTheme = .appleProDark) {
            let dark = theme.isDark
            let amber = dark
                ? Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
                : Color(red: 0xA8 / 255.0, green: 0x4B / 255.0, blue: 0x00 / 255.0)
            self.isDark = dark
            self.accent = theme.accentColor
            self.proBrandAmber = amber
            self.healthy = dark
                ? Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
                : Color(red: 0x1E / 255.0, green: 0x8E / 255.0, blue: 0x3E / 255.0)
            self.warning = amber
            self.critical = dark
                ? Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
                : Color(red: 0xD9 / 255.0, green: 0x2B / 255.0, blue: 0x20 / 255.0)
            self.running = dark
                ? Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
                : Color(red: 0x00 / 255.0, green: 0x71 / 255.0, blue: 0xA4 / 255.0)
            self.neutral = Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
            self.cardFill = dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
            self.inputFill = dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
            self.borderSubtle = dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
            self.borderFocus = theme.accentColor.opacity(0.75)
            self.hairline = dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
        }

        var proBrandAmberButtonInk: Color {
            isDark
                ? Color(red: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0)
                : .white
        }

        func badgeFill(for tint: Color) -> Color {
            tint.opacity(isDark ? 0.20 : 0.14)
        }

        func pillFill(for tint: Color) -> Color {
            tint.opacity(isDark ? 0.18 : 0.12)
        }
    }

    enum Radius {
        static let card: CGFloat = 16
        static let innerCard: CGFloat = 12
        static let input: CGFloat = 10
        static let pill: CGFloat = 16
        static let tagChip: CGFloat = 6
    }

    enum Layout {
        static let minTapTarget: CGFloat = 44
        static let readableHeroWidth: CGFloat = 480
        static let readableFormWidth: CGFloat = 560
        static let readableOverlayWidth: CGFloat = 400
    }
}

/// Crisp continuous-corner squircle icon with specular rim and optional 12×12 cutout status LED badge.
struct ProSquircleIcon: View {
    enum Size: CGFloat, Sendable {
        case compact = 32
        case row = 36
        case hero = 60
    }

    enum Emphasis: Sendable {
        case standard
        case selected
        case hero
    }

    let symbolName: String
    let tint: Color
    var size: Size = .row
    var emphasis: Emphasis = .standard
    var isDark: Bool = true
    var statusLED: Color? = nil
    var statusGlow: Bool = true

    init(
        symbolName: String,
        tint: Color,
        size: Size = .row,
        emphasis: Emphasis = .standard,
        isDark: Bool = true,
        statusLED: Color? = nil,
        statusGlow: Bool = true
    ) {
        self.symbolName = symbolName
        self.tint = tint
        self.size = size
        self.emphasis = emphasis
        self.isDark = isDark
        self.statusLED = statusLED
        self.statusGlow = statusGlow
    }

    init(
        symbolName: String,
        tint: Color,
        size: Size = .row,
        emphasis: Emphasis = .standard,
        theme: TerminalTheme,
        statusLED: Color? = nil,
        statusGlow: Bool = true
    ) {
        self.init(
            symbolName: symbolName,
            tint: tint,
            size: size,
            emphasis: emphasis,
            isDark: theme.isDark,
            statusLED: statusLED,
            statusGlow: statusGlow
        )
    }

    private var fillOpacity: Double {
        switch emphasis {
        case .standard: isDark ? 0.18 : 0.12
        case .selected: isDark ? 0.28 : 0.18
        case .hero: isDark ? 0.22 : 0.14
        }
    }

    private var rimOpacity: Double {
        switch emphasis {
        case .standard: 0.36
        case .selected: 0.72
        case .hero: 0.46
        }
    }

    private var rimLineWidth: CGFloat {
        switch emphasis {
        case .standard: 0.5
        case .selected: 1.2
        case .hero: 0.75
        }
    }

    var body: some View {
        let side = size.rawValue
        let cornerRadius = side * (10.0 / 36.0)
        let ledSize: CGFloat = size == .hero ? 8 : 7

        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(fillOpacity))

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tint.opacity(rimOpacity), tint.opacity(rimOpacity * 0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: rimLineWidth
                    )

                Image(systemName: symbolName)
                    .font(.system(size: side * 0.44, weight: .semibold))
                    .foregroundStyle(tint)

                if statusLED != nil {
                    Circle()
                        .frame(width: 12, height: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 2, y: 2)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()

            if let statusLED {
                ProStatusLED(color: statusLED, size: ledSize, glow: statusGlow)
                    .frame(width: 12, height: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: side, height: side)
        .shadow(
            color: emphasis == .hero ? tint.opacity(isDark ? 0.16 : 0.10) : .clear,
            radius: emphasis == .hero ? 8 : 0,
            y: emphasis == .hero ? 2 : 0
        )
        .accessibilityHidden(true)
    }
}

/// Glowing status LED dot with optional reduce-motion-aware pulse ring.
struct ProStatusLED: View {
    let color: Color
    var size: CGFloat = 7
    var glow: Bool = true
    var pulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var shouldPulse: Bool {
        pulse && !reduceMotion
    }

    var body: some View {
        ZStack {
            if shouldPulse {
                Circle()
                    .stroke(color.opacity(isPulsing ? 0 : 0.55), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 1.9 : 1.0)
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: glow ? color.opacity(0.6) : .clear, radius: glow ? 3 : 0)
        }
        .onAppear {
            updatePulseAnimation()
        }
        .onChange(of: pulse) { _, _ in
            updatePulseAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updatePulseAnimation()
        }
        .accessibilityHidden(true)
    }

    private func updatePulseAnimation() {
        if shouldPulse {
            isPulsing = false
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        } else {
            withAnimation(.none) {
                isPulsing = false
            }
        }
    }
}

/// Feature bullet descriptor displayed inside `ProFeatureGateView`.
struct ProFeatureItem: Identifiable, Sendable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    init(
        id: String? = nil,
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) {
        self.id = id ?? "\(icon)-\(title)"
        self.icon = icon
        self.tint = tint
        self.title = title
        self.detail = detail
    }
}

/// Reusable Pro upgrade view shared by gated feature tabs and dashboards.
struct ProFeatureGateView: View {
    let symbolName: String
    let title: String
    let subtitle: String
    let features: [ProFeatureItem]
    let theme: TerminalTheme
    let onUnlock: () -> Void

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    ProSquircleIcon(
                        symbolName: symbolName,
                        tint: palette.proBrandAmber,
                        size: .hero,
                        emphasis: .hero,
                        theme: theme
                    )

                    Text(title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !features.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(features.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider()
                            }
                            HStack(alignment: .top, spacing: 12) {
                                ProSquircleIcon(
                                    symbolName: item.icon,
                                    tint: item.tint,
                                    size: .row,
                                    emphasis: .standard,
                                    theme: theme
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.headline)

                                    Text(item.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .proSurfaceCard(theme: theme)
                }

                Button {
                    AppHaptics.impact(.light)
                    onUnlock()
                } label: {
                    Label("Unlock AmberTTY Pro", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.proBrandAmberButtonInk)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(palette.proBrandAmber)
            }
            .frame(maxWidth: ProDesign.Layout.readableHeroWidth)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Key-value row that stacks vertically at accessibility Dynamic Type sizes and sits horizontally otherwise.
struct AdaptiveKeyValueRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let spacing: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    init(
        spacing: CGFloat = 8,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.spacing = spacing
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: spacing) {
                leading
                Spacer(minLength: spacing)
                trailing
            }
        }
    }
}

extension View {
    /// Applies the standard Pro surface card fill and crisp 1pt (or 1.5pt focused) border.
    func proSurfaceCard(
        theme: TerminalTheme,
        cornerRadius: CGFloat = ProDesign.Radius.card,
        isFocused: Bool = false
    ) -> some View {
        let palette = ProDesign.Palette(theme: theme)
        return background(
            palette.cardFill,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? palette.borderFocus : palette.borderSubtle,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
    }

    /// Ensures at least a 44×44 pt hit target with a rectangular hit shape.
    func minTapTarget() -> some View {
        frame(
            minWidth: ProDesign.Layout.minTapTarget,
            minHeight: ProDesign.Layout.minTapTarget
        )
        .contentShape(Rectangle())
    }
}
