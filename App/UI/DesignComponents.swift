import SwiftUI
import UIKit
import SSHKit
import Store
import TermUI

@MainActor
enum AppHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard AppearanceSettings.hapticsEnabled() else { return }
        switch style {
        case .light: light.impactOccurred()
        case .medium: medium.impactOccurred()
        case .heavy: heavy.impactOccurred()
        case .soft: soft.impactOccurred()
        case .rigid: rigid.impactOccurred()
        @unknown default:
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppearanceSettings.hapticsEnabled() else { return }
        notification.notificationOccurred(type)
    }
}

/// Theme-aware translucent backdrop for reconnect and host-gone overlays.
struct ThemedOverlayBackground: View {
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            theme.backgroundColor.opacity(0.88)
        }
        .ignoresSafeArea()
    }
}

/// Crisp monospaced fingerprint card with optional key-type badge and explicit Copy feedback.
struct FingerprintCard: View {
    let title: String?
    let keyType: String?
    let fingerprint: String
    var accent: Color? = nil

    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var cardBackground: Color {
        if let accent {
            return accent.opacity(theme.isDark ? 0.14 : 0.08)
        }
        return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        if let accent {
            return accent.opacity(0.55)
        }
        return theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }

    init(title: String? = nil, keyType: String? = nil, fingerprint: String, accent: Color? = nil) {
        self.title = title
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent ?? .secondary)
                }
                if let keyType, !keyType.isEmpty {
                    Text(keyType)
                        .font(.caption2.monospaced().weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 8)
                Button {
                    copyFingerprint()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(copied ? Color.green : theme.accentColor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(copied ? "Copied fingerprint" : "Copy fingerprint")
            }

            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: accent == nil ? 1 : 1.5)
        )
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copyFingerprint() {
        UIPasteboard.general.string = fingerprint
        AppHaptics.notify(.success)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Unified authentication prompt used by both inline/modal host connections and reconnect overlays.
struct AuthPromptView: View {
    let request: HostConnectionModel.InputRequest
    var subtitle: String? = nil
    let onSubmit: ([String], Bool) -> Void
    let onCancel: () -> Void

    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var answers: [String]
    @State private var savePassphrase = false
    @FocusState private var focusedIndex: Int?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var canSubmit: Bool {
        request.purpose == .keyboardInteractive || !(answers.first ?? "").isEmpty
    }

    private var iconName: String {
        switch request.purpose {
        case .password: "lock.fill"
        case .passphrase: "key.fill"
        case .keyboardInteractive: "person.badge.key.fill"
        }
    }

    init(
        request: HostConnectionModel.InputRequest,
        subtitle: String? = nil,
        onSubmit: @escaping ([String], Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.subtitle = subtitle
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _answers = State(initialValue: request.prefill)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                fieldsSection
                actionsSection
            }
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if !request.items.isEmpty {
                focusedIndex = 0
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(theme.accentColor)
                .padding(.bottom, 2)
                .accessibilityHidden(true)

            Text(request.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !request.instruction.isEmpty {
                Text(request.instruction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(spacing: 12) {
            ForEach(request.items.indices, id: \.self) { index in
                fieldRow(at: index)
            }

            if request.purpose == .passphrase {
                Toggle("Save passphrase", isOn: $savePassphrase)
                    .padding(.top, 2)
            }
        }
    }

    private func fieldRow(at index: Int) -> some View {
        let item = request.items[index]
        let isFocused = focusedIndex == index
        let isLast = index == request.items.count - 1
        let fieldFill = theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
        let unfocusedBorder = theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        let borderColor = isFocused ? theme.accentColor.opacity(0.75) : unfocusedBorder
        let binding = Binding<String>(
            get: { index < answers.count ? answers[index] : "" },
            set: { newValue in
                if index < answers.count {
                    answers[index] = newValue
                }
            }
        )

        return Group {
            if item.echo {
                TextField(item.text, text: binding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(item.text, text: binding)
            }
        }
        .focused($focusedIndex, equals: index)
        .submitLabel(isLast ? .continue : .next)
        .onSubmit {
            if index + 1 < request.items.count {
                focusedIndex = index + 1
            } else if canSubmit {
                onSubmit(answers, savePassphrase)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(fieldFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var actionsSection: some View {
        VStack(spacing: 10) {
            Button {
                AppHaptics.impact(.light)
                onSubmit(answers, savePassphrase)
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)

            Button(role: .cancel) {
                AppHaptics.impact(.light)
                onCancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// Wrapping flow layout shared by host badge rows and host tag editors.
struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension LiveSession.ConnectionStatus {
    var accessibilityLabel: String {
        switch self {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        }
    }
}

/// Environment category inferred from a host's tags, label, and hostname.
enum HostEnvironment: Sendable, Equatable {
    case prod
    case homelab
    case database
    case cloud

    private static let prodTokens: Set<String> = ["prod", "production", "api", "live", "web"]
    private static let homelabTokens: Set<String> = ["homelab", "home", "local", "lan", "mac", "nas", "pi"]
    private static let databaseTokens: Set<String> = [
        "db", "sql", "postgres", "postgresql", "mysql", "redis", "mongo", "mongodb", "staging", "stage",
    ]

    static func classify(tags: [String], label: String, hostname: String) -> HostEnvironment {
        let lowerHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isLocalSuffix = lowerHost.hasSuffix(".local") || lowerHost.hasSuffix(".ts.net")

        var tokens = Set<String>()
        for source in tags + [label, hostname] {
            extractTokens(from: source, into: &tokens)
        }

        if !tokens.isDisjoint(with: prodTokens) {
            return .prod
        }
        if isLocalSuffix || !tokens.isDisjoint(with: homelabTokens) {
            return .homelab
        }
        if !tokens.isDisjoint(with: databaseTokens) {
            return .database
        }
        return .cloud
    }

    private static func extractTokens(from text: String, into result: inout Set<String>) {
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(piece)
            result.insert(word)
            let alphaPrefix = word.prefix(while: \.isLetter)
            if alphaPrefix.count >= 2 && alphaPrefix.count < word.count {
                result.insert(String(alphaPrefix))
            }
        }
    }

    var symbolName: String {
        switch self {
        case .prod: "server.rack"
        case .homelab: "desktopcomputer"
        case .database: "cylinder.split.1x2.fill"
        case .cloud: "cloud.fill"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .prod:
            [Color(red: 0xFF / 255, green: 0x5B / 255, blue: 0x4D / 255),
             Color(red: 0xE0 / 255, green: 0x3A / 255, blue: 0x2E / 255)]
        case .homelab:
            [Color(red: 0x3E / 255, green: 0xC6 / 255, blue: 0xDC / 255),
             Color(red: 0x1E / 255, green: 0x8F / 255, blue: 0xA5 / 255)]
        case .database:
            [Color(red: 0x6F / 255, green: 0x6D / 255, blue: 0xF2 / 255),
             Color(red: 0x49 / 255, green: 0x47 / 255, blue: 0xC9 / 255)]
        case .cloud:
            [Color(red: 0x6E / 255, green: 0x71 / 255, blue: 0x7A / 255),
             Color(red: 0x4B / 255, green: 0x4E / 255, blue: 0x56 / 255)]
        }
    }
}

/// Crisp 36×36 pt continuous-corner squircle icon with a subtle specular rim.
struct SquircleIcon: View {
    private let backgroundStyle: AnyShapeStyle
    private let symbolName: String
    private let symbolColor: Color
    private let rimColors: [Color]
    private let size: CGFloat

    init(
        symbolName: String,
        gradientColors: [Color],
        symbolColor: Color = .white,
        rimColors: [Color] = [Color.white.opacity(0.22), Color.white.opacity(0.04)],
        size: CGFloat = 36
    ) {
        self.symbolName = symbolName
        self.backgroundStyle = AnyShapeStyle(
            LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
        )
        self.symbolColor = symbolColor
        self.rimColors = rimColors
        self.size = size
    }

    init(
        symbolName: String,
        tint: Color,
        fillOpacity: Double,
        rimOpacity: Double,
        size: CGFloat = 36
    ) {
        self.symbolName = symbolName
        self.backgroundStyle = AnyShapeStyle(tint.opacity(fillOpacity))
        self.symbolColor = tint
        self.rimColors = [tint.opacity(rimOpacity), tint.opacity(rimOpacity * 0.45)]
        self.size = size
    }

    var body: some View {
        let cornerRadius = size * (10.0 / 36.0)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundStyle)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: rimColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            Image(systemName: symbolName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Environment-coded 36×36 pt squircle badge rendered on host launchpad rows.
struct HostEnvironmentIcon: View {
    let host: Host

    private var environment: HostEnvironment {
        HostEnvironment.classify(tags: host.tags, label: host.label, hostname: host.hostname)
    }

    var body: some View {
        SquircleIcon(
            symbolName: environment.symbolName,
            gradientColors: environment.gradientColors
        )
    }
}
