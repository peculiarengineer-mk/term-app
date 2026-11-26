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

    private var hostDisplay: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    Text("Host key changed")
                        .font(.title2.bold())
                        .foregroundStyle(.red)

                    Text("The key for \(hostname):\(port) does not match the one you trusted. The connection was blocked. This can mean the server was rebuilt, or that someone is intercepting your connection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                FingerprintCard(title: "Stored", fingerprint: stored)

                FingerprintCard(
                    title: "Presented",
                    keyType: presented.type.rawValue,
                    fingerprint: presented.fingerprint,
                    accent: .red
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
                        AppHaptics.impact(.light)
                        onClose()
                    } label: {
                        Text("Close")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        AppHaptics.impact(.medium)
                        confirming = true
                    } label: {
                        Text("Replace stored key")
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
        .confirmationDialog("Replace the stored key for \(hostDisplay)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace stored key", role: .destructive, action: onReplace)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if you know the server's key changed.")
        }
    }
}
