import SafariServices
import SwiftUI
import TermUI
import UIKit

/// SwiftUI wrapper around `SFSafariViewController` for previewing forwarded local dev servers in-app.
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL
    var theme: TerminalTheme = .appleProDark

    static func isSupportedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    static func makeViewController(for url: URL, theme: TerminalTheme = .appleProDark) -> UIViewController {
        guard isSupportedURL(url) else {
            return UIHostingController(rootView: UnsupportedPreviewURLView(scheme: url.scheme))
        }
        let controller = SFSafariViewController(url: url)
        applyTheme(theme, to: controller)
        controller.dismissButtonStyle = .close
        return controller
    }

    func makeUIViewController(context: Context) -> UIViewController {
        Self.makeViewController(for: url, theme: theme)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let safari = uiViewController as? SFSafariViewController {
            Self.applyTheme(theme, to: safari)
        }
    }

    private static func applyTheme(_ theme: TerminalTheme, to controller: SFSafariViewController) {
        controller.preferredBarTintColor = UIColor(theme.backgroundColor)
        controller.preferredControlTintColor = UIColor(theme.accentColor)
    }
}

private struct UnsupportedPreviewURLView: View {
    let scheme: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Unsupported Preview URL",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    scheme.map { "The \"\($0)\" URL scheme cannot be previewed. Only http and https URLs are supported." }
                        ?? "Only http and https URLs are supported."
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
