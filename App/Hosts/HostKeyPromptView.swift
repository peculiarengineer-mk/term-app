import SwiftUI
import SSHKit
import TermUI

/// Trust-on-first-use prompt for a host key not seen before.
struct HostKeyPromptView: View {
    let hostname: String
    let port: Int
    let key: HostKey
    let onTrust: () -> Void
    let onCancel: () -> Void

    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .accessibilityHidden(true)

                    Text("New host")
                        .font(.title2.bold())

                    Text("The authenticity of \(hostname):\(port) can't be established. Check this fingerprint against your server before trusting it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                FingerprintCard(
                    title: "Host Key",
                    keyType: key.type.rawValue,
                    fingerprint: key.fingerprint
                )
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 10) {
                    Button {
                        AppHaptics.impact(.medium)
                        onTrust()
                    } label: {
                        Text("Trust")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

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
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(.bar)
        }
    }
}
