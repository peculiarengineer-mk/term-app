import SwiftUI
import SSHKit

/// Trust-on-first-use prompt for a host key not seen before.
struct HostKeyPromptView: View {
    let hostname: String
    let port: Int
    let key: HostKey
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New host").font(.title2.bold())
            Text("The authenticity of \(hostname):\(port) can't be established. Check this fingerprint against your server before trusting it.")
            Text(key.type.rawValue).font(.footnote).foregroundStyle(.secondary)
            Text(key.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Trust", action: onTrust).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Cancel", role: .cancel, action: onCancel).frame(maxWidth: .infinity)
        }
        .padding()
    }
}
