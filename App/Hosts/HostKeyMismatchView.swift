import SwiftUI
import SSHKit

/// Full-screen block shown when a server's key differs from the stored one. Nothing is sent to the server.
struct HostKeyMismatchView: View {
    let hostname: String
    let port: Int
    let stored: String
    let presented: HostKey
    let onReplace: () -> Void
    let onClose: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Host key changed", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            Text("The key for \(hostname):\(port) does not match the one you trusted. The connection was blocked. This can mean the server was rebuilt, or that someone is intercepting your connection.")
            Text("Stored").font(.footnote).foregroundStyle(.secondary)
            Text(stored).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("Presented").font(.footnote).foregroundStyle(.secondary)
            Text(presented.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Close", action: onClose).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Replace stored key", role: .destructive) { confirming = true }
                .frame(maxWidth: .infinity)
        }
        .padding()
        .confirmationDialog("Replace the stored key for \(hostname)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace stored key", role: .destructive, action: onReplace)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if you know the server's key changed.")
        }
    }
}
