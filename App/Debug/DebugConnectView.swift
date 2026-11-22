#if DEBUG
import SwiftUI
import SSHKit
import TermUI

/// DEBUG-ONLY. Connects with a typed password and TRUSTS ANY HOST KEY. Never ships in release builds.
struct DebugConnectView: View {
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var bridge: SessionBridge?
    @State private var connection: SSHConnection?
    @State private var status = ""
    @State private var connecting = false
    @State private var connectTask: Task<Void, Never>?
    @State private var controller = TerminalController()

    var body: some View {
        Group {
            if let bridge {
                TerminalHostView(io: bridge, controller: controller)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Disconnect") { disconnect() }
                        }
                    }
            } else {
                Form {
                    Section {
                        Text("DEBUG ONLY: trusts any host key. Not for real servers you care about.")
                            .foregroundStyle(.red)
                    }
                    Section("Server") {
                        TextField("Host", text: $host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("User", text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                    Button("Connect") { connect() }.disabled(host.isEmpty || user.isEmpty || connecting)
                    if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Debug connect")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { disconnect() }
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        status = "Connecting…"
        let conn = SSHConnection(host: host, username: user, auth: .password(password))
        connectTask = Task {
            do {
                try await conn.connect { _ in .trust }
                if Task.isCancelled { await conn.close(); return }  // left the screen mid-connect
                connecting = false
                connection = conn
                bridge = SessionBridge(session: conn)
                status = ""
            } catch {
                if Task.isCancelled { return }  // the view is gone
                connecting = false
                status = "Failed: \(error)"
            }
        }
    }

    private func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connecting = false
        let conn = connection
        bridge = nil
        connection = nil
        Task { await conn?.close() }
    }
}
#endif
