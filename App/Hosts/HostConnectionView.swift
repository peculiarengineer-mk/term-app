import SwiftUI
import SSHKit
import Store
import TermUI

struct HostConnectionView: View {
    let host: Host
    private let externalModel: HostConnectionModel?
    private let onConnected: ((UUID) -> Void)?
    private let onCancel: (() -> Void)?

    @State private var ownedModel: HostConnectionModel?
    @State private var didStart = false
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var manager
    @Environment(\.openSessionTab) private var openTab
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var activeModel: HostConnectionModel? {
        externalModel ?? ownedModel
    }

    private var hostTitle: String {
        if let modelTitle = activeModel?.title, !modelTitle.isEmpty { return modelTitle }
        return host.label.isEmpty ? host.hostname : host.label
    }

    private var addressSubtitle: String {
        let username = activeModel?.username ?? host.username
        let port = activeModel?.port ?? host.port
        let hostname = activeModel?.hostname ?? host.hostname
        let userPart = username.isEmpty ? "" : "\(username)@"
        let portPart = port == 22 ? "" : ":\(port)"
        return "\(userPart)\(hostname)\(portPart)"
    }

    init(
        host: Host,
        model: HostConnectionModel? = nil,
        onConnected: ((UUID) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.host = host
        self.externalModel = model
        self.onConnected = onConnected
        self.onCancel = onCancel
        _ownedModel = State(initialValue: model == nil ? HostConnectionModel(host: host) : nil)
    }

    var body: some View {
        Group {
            if let model = activeModel {
                switch model.phase {
                case .input(let request):
                    AuthPromptView(
                        request: request,
                        subtitle: addressSubtitle,
                        onSubmit: { model.submitInput(request, answers: $0, savePassphrase: $1) },
                        onCancel: { model.cancelInput(request) }
                    )
                    .id(request.id)

                case .connecting:
                    connectingCard

                case .prompt(let key):
                    HostKeyPromptView(
                        hostname: model.hostKeyPromptHostname,
                        port: model.hostKeyPromptPort,
                        key: key,
                        onTrust: { model.trust(key) },
                        onCancel: { model.cancelPrompt() }
                    )

                case .mismatch(let stored, let presented):
                    HostKeyMismatchView(
                        hostname: model.hostKeyPromptHostname,
                        port: model.hostKeyPromptPort,
                        stored: stored,
                        presented: presented,
                        onReplace: { model.replaceStoredKey(with: presented) },
                        onClose: { closeConnection() }
                    )

                case .connected:
                    statusCard {
                        ProgressView()
                            .controlSize(.large)
                        VStack(spacing: 4) {
                            Text(hostTitle)
                                .font(.title3.bold())
                                .multilineTextAlignment(.center)
                            Text(addressSubtitle)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("Opening session…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                case .keyMissing(let keyName):
                    KeyMissingView(
                        host: host,
                        keyName: keyName,
                        onRetry: {
                            model.refresh(from: host)
                            model.start()
                        },
                        onClose: { closeConnection() }
                    )

                case .failed(let message):
                    statusCard {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)

                        VStack(spacing: 4) {
                            Text(hostTitle)
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
                                model.retry()
                            } label: {
                                Text("Retry")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button(role: .cancel) {
                                closeConnection()
                            } label: {
                                Text(onCancel == nil ? "Close" : "Close Tab")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
            } else {
                connectingCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.backgroundColor.ignoresSafeArea())
        .navigationTitle(hostTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onCancel == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { closeConnection() }
                }
            }
        }
        .onAppear {
            startOwnedModelIfNeeded()
        }
        .onChange(of: externalModel != nil) { _, hasExternalModel in
            if hasExternalModel {
                if let ownedModel {
                    ownedModel.teardown()
                    self.ownedModel = nil
                }
                didStart = false
            } else {
                startOwnedModelIfNeeded()
            }
        }
        .onDisappear {
            if externalModel == nil {
                activeModel?.teardown()
                didStart = false
            }
        }
    }

    private var connectingCard: some View {
        statusCard {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text(hostTitle)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(addressSubtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Connecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(role: .cancel) {
                closeConnection()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func startOwnedModelIfNeeded() {
        guard externalModel == nil, !didStart else { return }
        let currentModel: HostConnectionModel
        if let ownedModel {
            currentModel = ownedModel
        } else {
            let created = HostConnectionModel(host: host)
            ownedModel = created
            currentModel = created
        }
        didStart = true
        // Title and tmux are read when the connection lands, so an edit made from the key-missing screen applies.
        currentModel.onConnected = { [manager, openTab, hostID = host.id, onConnected, dismiss, weak currentModel] conn, bridge in
            let title = currentModel?.title ?? ""
            let tmux = currentModel?.tmux
            let live = manager.open(
                hostID: hostID,
                title: title,
                session: conn,
                bridge: bridge,
                ephemeralHost: host.modelContext == nil ? host : nil
            ) // wiring: T8
            TmuxAttach.send(tmux, via: bridge) // wiring: T9
            if let onConnected {
                onConnected(live.id)
            } else {
                openTab(live.id)
                dismiss()
            }
        }
        currentModel.start()
    }

    private func closeConnection() {
        AppHaptics.impact(.light)
        activeModel?.teardown()
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            content()
        }
        .frame(maxWidth: 380)
        .padding(24)
        .background(
            theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(24)
    }
}
