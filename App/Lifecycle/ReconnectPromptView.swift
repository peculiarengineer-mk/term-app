import SwiftUI
import SSHKit

/// Drawn over a dead session's terminal (through `LiveSession.overlay`). Shows a Reconnect button
/// when the user has to take part, then the same host-key and auth screens as a first connect.
struct ReconnectPromptView: View {
    let model: HostConnectionModel
    let title: String
    let onClose: () -> Void
    /// True once the user pressed Reconnect (or the coordinator started the flow itself).
    let started: Bool
    let onReconnect: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                if !started {
                    Text("Disconnected from \(title)").font(.headline)
                    Button("Reconnect", action: onReconnect).buttonStyle(.borderedProminent)
                    Button("Close Tab", role: .destructive, action: onClose)
                } else {
                    content
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .input(let request):
            ReconnectInputForm(request: request,
                               onSubmit: { model.submitInput(request, answers: $0, savePassphrase: $1) },
                               onCancel: { model.cancelInput(request) })
                .id(request.id)
        case .connecting, .connected:
            ProgressView("Reconnecting…")
        case .prompt(let key):
            HostKeyPromptView(hostname: model.hostname, port: model.port, key: key,
                              onTrust: { model.trust(key) }, onCancel: { model.cancelPrompt() })
        case .mismatch(let stored, let presented):
            HostKeyMismatchView(hostname: model.hostname, port: model.port, stored: stored, presented: presented,
                                onReplace: { model.replaceStoredKey(with: presented) },
                                onClose: onClose)
        case .keyMissing:
            Text("Key not on this device").font(.headline)
            Text("This host uses a key that is not in this device's Keychain. It may not have synced, or it was deleted.")
                .font(.footnote)
            Button("Reconnect") { model.retry() }.buttonStyle(.borderedProminent)
            Button("Close Tab", role: .destructive, action: onClose)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Reconnect") { model.retry() }.buttonStyle(.borderedProminent)
            Button("Close Tab", role: .destructive, action: onClose)
        }
    }
}

private struct ReconnectInputForm: View {
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
        VStack(spacing: 12) {
            Text(request.title).font(.headline)
            if !request.instruction.isEmpty { Text(request.instruction).font(.footnote) }
            ForEach(request.items.indices, id: \.self) { i in
                let item = request.items[i]
                let binding = Binding(get: { i < answers.count ? answers[i] : "" },
                                      set: { if i < answers.count { answers[i] = $0 } })
                Group {
                    if item.echo {
                        TextField(item.text, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField(item.text, text: binding)
                    }
                }.textFieldStyle(.roundedBorder)
            }
            if request.purpose == .passphrase { Toggle("Save passphrase", isOn: $savePassphrase) }
            Button("Continue") { onSubmit(answers, savePassphrase) }
                .buttonStyle(.borderedProminent)
                .disabled(request.purpose != .keyboardInteractive && (answers.first ?? "").isEmpty)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .frame(maxWidth: 420)
    }
}

/// Shown on a dead tab whose host was deleted.
struct HostGoneView: View {
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color(.systemBackground).opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Host no longer exists").font(.headline)
                Button("Close Tab", role: .destructive, action: onClose)
            }.padding()
        }
    }
}
