import SwiftUI
import UIKit

/// App-level phase: `.active` while any scene is active, `.background` once every scene is in the
/// background. A single window's `scenePhase` would flip when only one iPad window changes.
@MainActor @Observable
final class AppPhaseMonitor {
    enum Phase: Sendable { case active, inactive, background }

    private(set) var phase: Phase = .inactive
    /// Called on the transition into `.active` (not on repeated activations).
    var onBecameActive: (() -> Void)?
    /// Called when every scene is in the background.
    var onBecameBackground: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didDisconnectNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        let scenes = UIApplication.shared.connectedScenes
        let new: Phase
        if scenes.contains(where: { $0.activationState == .foregroundActive }) { new = .active }
        else if scenes.contains(where: { $0.activationState == .foregroundInactive }) { new = .inactive }
        else { new = .background }
        let old = phase
        phase = new
        if new == .active, old != .active { onBecameActive?() }
        if new == .background, old != .background { onBecameBackground?() }
    }
}
