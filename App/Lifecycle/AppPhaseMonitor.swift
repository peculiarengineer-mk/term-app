import SwiftUI
import UIKit

/// App-level phase: `.active` while any scene is active, `.background` once every scene is in the
/// background. A single window's `scenePhase` would flip when only one iPad window changes.
@MainActor @Observable
final class AppPhaseMonitor {
    enum Phase: Sendable { case active, inactive, background }

    private(set) var phase: Phase = .inactive
    /// Called on the transition into `.active` (not on repeated activations).
    /// The argument is `true` only when returning from `.background`, not transient `.inactive`.
    var onBecameActive: ((_ fromBackground: Bool) -> Void)?
    /// Called when every scene is in the background.
    var onBecameBackground: (() -> Void)?
    private var wasBackground = false
    private let observers = ObserverBag()

    // @unchecked Sendable: guarded by lock; tokens are added on MainActor in start() and removed in deinit.
    private final class ObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [NSObjectProtocol] = []
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return tokens.isEmpty }
        func append(_ token: NSObjectProtocol) { lock.lock(); tokens.append(token); lock.unlock() }
        func removeAll() {
            lock.lock()
            let current = tokens
            tokens = []
            lock.unlock()
            let center = NotificationCenter.default
            for token in current { center.removeObserver(token) }
        }
    }

    deinit {
        observers.removeAll()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                     UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
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
        if new == .background {
            wasBackground = true
            if old != .background { onBecameBackground?() }
        } else if new == .active {
            let fromBackground = wasBackground
            wasBackground = false
            if old != .active { onBecameActive?(fromBackground) }
        }
    }
}
