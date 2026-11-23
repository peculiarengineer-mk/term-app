import SwiftUI
import SwiftData
import SSHKit
import Store
import TermUI

/// Drawn over a dead session's terminal (through `LiveSession.overlay`). Shows a Reconnect button
/// when the user has to take part, then the same host-key and auth screens as a first connect.
struct ReconnectPromptView: View {
    let model: HostConnectionModel
    let title: String
    let onClose: () -> Void
    /// True once the user pressed Reconnect (or the coordinator started the flow itself).
    let started: Bool
    let onReconnect: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var addressSubtitle: String {
        let userPart = model.username.isEmpty ? "" : "\(model.username)@"
        let portPart = model.port == 22 ? "" : ":\(model.port)"
        return "\(userPart)\(model.hostname)\(portPart)"
    }

    private var resolvedHost: Host? {
        let targetID = model.hostID
        var descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.id == targetID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    var body: some View {
        ZStack {
            ThemedOverlayBackground()
            if !started {
                overlayCard {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(spacing: 4) {
                        Text("Disconnected from \(title)")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                        Text(addressSubtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        Button {
                            AppHaptics.impact(.light)
                            onReconnect()
                        } label: {
                            Text("Reconnect")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(role: .destructive) {
                            AppHaptics.impact(.light)
                            onClose()
                        } label: {
                            Text("Close Tab")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .input(let request):
            AuthPromptView(
                request: request,
                subtitle: addressSubtitle,
                onSubmit: { model.submitInput(request, answers: $0, savePassphrase: $1) },
                onCancel: { model.cancelInput(request) }
            )
            .id(request.id)

        case .connecting, .connected:
            overlayCard {
                ProgressView()
                    .controlSize(.large)
                VStack(spacing: 4) {
                    Text("Reconnecting to \(title)…")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(addressSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

        case .prompt(let key):
            HostKeyPromptView(
                hostname: model.hostname,
                port: model.port,
                key: key,
                onTrust: { model.trust(key) },
                onCancel: { model.cancelPrompt() }
            )

        case .mismatch(let stored, let presented):
            HostKeyMismatchView(
                hostname: model.hostname,
                port: model.port,
                stored: stored,
                presented: presented,
                onReplace: { model.replaceStoredKey(with: presented) },
                onClose: onClose
            )

        case .keyMissing(let keyName):
            if let host = resolvedHost {
                KeyMissingView(
                    host: host,
                    keyName: keyName,
                    onRetry: onReconnect,
                    onClose: onClose
                )
            } else {
                overlayCard {
                    Image(systemName: "key.slash")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Key not on this device")
                        .font(.title3.bold())
                    Text("This host uses a key that is not in this device's Keychain, and the host record is no longer available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(role: .destructive) {
                        AppHaptics.impact(.light)
                        onClose()
                    } label: {
                        Text("Close Tab")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

        case .failed(let message):
            overlayCard {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(addressSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button {
                        AppHaptics.impact(.light)
                        onReconnect()
                    } label: {
                        Text("Reconnect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        AppHaptics.impact(.light)
                        onClose()
                    } label: {
                        Text("Close Tab")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }

    private func overlayCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            content()
        }
        .frame(maxWidth: 380)
        .padding(24)
        .background(
            theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1)
        )
        .padding(24)
    }
}

/// Shown on a dead tab whose host was deleted.
struct HostGoneView: View {
    let onClose: () -> Void
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ZStack {
            ThemedOverlayBackground()
            VStack(spacing: 18) {
                Image(systemName: "server.rack")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("Host no longer exists")
                    .font(.title3.bold())

                Button(role: .destructive) {
                    AppHaptics.impact(.light)
                    onClose()
                } label: {
                    Text("Close Tab")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: 360)
            .padding(24)
            .background(
                theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1)
            )
            .padding(24)
        }
    }
}
