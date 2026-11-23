import SwiftUI
import CoreText
import TermUI

struct SettingsView: View {
    @Environment(AppLockManager.self) private var appLock
    @AppStorage("sync.enabled") private var syncEnabled = false
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage(AppearanceSettings.fontSizeKey) private var fontSize = AppearanceSettings.defaultFontSize
    @AppStorage(AppearanceSettings.fontFamilyKey) private var fontFamilyRaw = AppearanceSettings.defaultFontFamilyRaw
    @AppStorage(AppearanceSettings.cursorStyleKey) private var cursorStyleRaw = AppearanceSettings.defaultCursorStyleRaw
    @AppStorage(AppearanceSettings.hapticsKey) private var hapticsEnabled = AppearanceSettings.defaultHapticsEnabled
    @State private var securityError: String?

    private var currentTheme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var fontFamily: TerminalFontFamily { TerminalFontFamily(rawValue: fontFamilyRaw) ?? .sfMono }
    private var cursorStyle: TerminalCursorStyle { TerminalCursorStyle(rawValue: cursorStyleRaw) ?? .block }

    private var previewFont: Font {
        Font(fontFamily.uiFont(ofSize: CGFloat(fontSize)) as CTFont)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    HStack {
                        Text("Theme")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(currentTheme.backgroundColor)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.75))
                                .frame(width: 14, height: 14)
                            Text(currentTheme.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(TerminalFontFamily.allCases) { family in
                        Text(family.rawValue).tag(family.rawValue)
                    }
                }

                Picker("Cursor", selection: $cursorStyleRaw) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text(AppearanceSettings.formattedFontSize(fontSize))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(
                            value: $fontSize,
                            in: AppearanceSettings.minFontSize...AppearanceSettings.maxFontSize,
                            step: 0.5
                        ) {
                            Text("Font Size")
                        }
                        Image(systemName: "textformat.size.larger")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .bottom, spacing: 0) {
                            Text("dev@prod")
                                .foregroundStyle(currentTheme.ansi[2].color)
                            Text(":~/app$ ")
                                .foregroundStyle(currentTheme.ansi[4].color)
                            Text("ssh -V")
                                .foregroundStyle(currentTheme.foregroundColor)
                            previewCursor
                                .padding(.leading, 2)
                        }
                        Text("OpenSSH_9.9, libssh2 PQ")
                            .foregroundStyle(currentTheme.secondaryForegroundColor)
                    }
                    .font(previewFont)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(currentTheme.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                currentTheme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Terminal preview: \(fontFamily.rawValue), \(AppearanceSettings.formattedFontSize(fontSize)), \(cursorStyle.rawValue.lowercased()) cursor")
                }
                .padding(.vertical, 4)

                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                    .onChange(of: hapticsEnabled) { _, on in
                        if on { AppHaptics.impact(.light) }
                    }
            }

            Section {
                NavigationLink("Command Snippets", destination: SnippetDrawerView(onRun: nil))
            }

            Section {
                Toggle("Face ID / Passcode Lock", isOn: Binding(
                    get: { appLock.appLockEnabled },
                    set: { enabled in
                        if enabled {
                            Task {
                                if let error = await appLock.enableWithAuthentication() {
                                    securityError = error
                                }
                            }
                        } else {
                            appLock.setEnabled(false)
                            securityError = nil
                        }
                    }
                ))
                .disabled(appLock.isAuthenticating)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks TermApp on launch and when returning from the background. Terminal screens are always blurred in the App Switcher.")
            }

            Section {
                Toggle("iCloud sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, on in
                        guard !on else { return }
                        SyncCoordinator.syncTurnedOff()
                    }
            } footer: {
                Text("Syncs saved hosts, saved passwords and trusted host keys through iCloud. Takes effect the next time the app opens. Turning sync off keeps everything on this device and leaves what is already in iCloud in place.")
            }
            Section {
                NavigationLink("Licences", destination: LicencesView())
            }
            #if DEBUG
            Section("Debug") {
                NavigationLink("Sync tools", destination: DebugSyncTools())
            }
            #endif
            Section {
                Text("To use Caps Lock as a modifier key, open Settings › General › Keyboard › Hardware Keyboard › Modifier Keys.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .alert(
            "App Lock Unavailable",
            isPresented: Binding(get: { securityError != nil }, set: { if !$0 { securityError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(securityError ?? "")
        }
    }

    @ViewBuilder
    private var previewCursor: some View {
        let cellHeight = max(10, CGFloat(fontSize) * 1.15)
        let cellWidth = max(6, CGFloat(fontSize) * 0.58)
        let stroke = max(2, CGFloat(fontSize) * 0.14)

        switch cursorStyle {
        case .block:
            Rectangle()
                .fill(currentTheme.cursor.color)
                .frame(width: cellWidth, height: cellHeight)
        case .bar:
            Rectangle()
                .fill(currentTheme.cursor.color)
                .frame(width: stroke, height: cellHeight)
        case .underline:
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: cellWidth, height: cellHeight)
                Rectangle()
                    .fill(currentTheme.cursor.color)
                    .frame(width: cellWidth, height: stroke)
            }
        }
    }
}
