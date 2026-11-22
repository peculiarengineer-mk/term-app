import SwiftUI
import SSHKit
import Store
import TermUI

struct HostConnectionView: View {
    let host: Host
    @State private var model: HostConnectionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var manager
    @Environment(\.openSessionTab) private var openTab

    init(host: Host) {
        self.host = host
        _model = State(initialValue: HostConnectionModel(host: host))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .input(let request):
                AuthPromptForm(request: request,
                               onSubmit: { model.submitInput(request, answers: $0, savePassphrase: $1) },
                               onCancel: { model.cancelInput(request) })
                    .id(request.id)
            case .connecting:
                ProgressView("Connecting…")
            case .prompt(let key):
                HostKeyPromptView(hostname: model.hostname, port: model.port, key: key,
                                  onTrust: { model.trust(key) }, onCancel: { model.cancelPrompt() })
            case .mismatch(let stored, let presented):
                HostKeyMismatchView(hostname: model.hostname, port: model.port, stored: stored, presented: presented,
                                    onReplace: { model.replaceStoredKey(with: presented) },
                                    onClose: { model.teardown(); dismiss() })
            case .connected:
                ProgressView("Opening…")
            case .keyMissing:
                KeyMissingView(host: host, onRetry: { model.refresh(from: host); model.start() })
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.red)
                    Button("Retry") { model.retry() }
                }.padding()
            }
        }
        .navigationTitle(host.label.isEmpty ? host.hostname : host.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { model.teardown(); dismiss() }
            }
        }
        .onAppear {
            // Title and tmux are read when the connection lands, so an edit made from the key-missing screen applies.
            model.onConnected = { [manager, openTab, hostID = host.id, weak model] conn, bridge in
                let title = model?.title ?? "", tmux = model?.tmux
                let live = manager.open(hostID: hostID, title: title, session: conn, bridge: bridge)  // wiring: T8
                TmuxAttach.send(tmux, via: bridge)  // wiring: T9
                openTab(live.id)
                dismiss()
            }
            model.start()
        }
        .onDisappear { model.teardown() }
    }
}

private struct AuthPromptForm: View {
    let request: HostConnectionModel.InputRequest
    let onSubmit: ([String], Bool) -> Void
    let onCancel: () -> Void
    @State private var answers: [String]
    @State private var savePassphrase = false

    init(request: HostConnectionModel.InputRequest,
         onSubmit: @escaping ([String], Bool) -> Void, onCancel: @escaping () -> Void) {
        self.request = request; self.onSubmit = onSubmit; self.onCancel = onCancel
        _answers = State(initialValue: request.prefill)
    }

    var body: some View {
        Form {
            Section {
                ForEach(request.items.indices, id: \.self) { i in
                    let item = request.items[i]
                    let binding = Binding(get: { i < answers.count ? answers[i] : "" },
                                          set: { if i < answers.count { answers[i] = $0 } })
                    if item.echo {
                        TextField(item.text, text: binding)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField(item.text, text: binding)
                    }
                }
            } header: {
                Text(request.title)
            } footer: {
                if !request.instruction.isEmpty { Text(request.instruction) }
            }
            if request.purpose == .passphrase {
                Section { Toggle("Save passphrase", isOn: $savePassphrase) }
            }
            Section {
                Button("Continue") { onSubmit(answers, savePassphrase) }
                    .disabled(request.purpose != .keyboardInteractive && (answers.first ?? "").isEmpty)
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
    }
}
