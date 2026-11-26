import SafariServices
import SwiftUI
import TermUI
import UIKit

/// SwiftUI wrapper around `SFSafariViewController` for previewing forwarded local dev servers in-app.
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL
    var theme: TerminalTheme = .appleProDark

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        applyTheme(to: controller)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        applyTheme(to: uiViewController)
    }

    private func applyTheme(to controller: SFSafariViewController) {
        controller.preferredBarTintColor = UIColor(theme.backgroundColor)
        controller.preferredControlTintColor = UIColor(theme.accentColor)
    }
}
