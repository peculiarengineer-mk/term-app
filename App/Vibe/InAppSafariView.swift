import SafariServices
import SwiftUI
import UIKit

/// SwiftUI wrapper around `SFSafariViewController` for previewing forwarded local dev servers in-app.
struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL
    var tintColor: Color = AgentVisuals.appleProAmber

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(tintColor)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        uiViewController.preferredControlTintColor = UIColor(tintColor)
    }
}
