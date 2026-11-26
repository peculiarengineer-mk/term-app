import SwiftUI
import UIKit
import LocalAuthentication
import TermUI

/// Manages app-wide Face ID / Passcode locking across scenes.
@MainActor @Observable
final class AppLockManager {
    static let defaultsKey = "security.appLock"

    private let defaults: UserDefaults
    private(set) var appLockEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var authError: String?
    /// Tracks whether the next `.active` transition should automatically trigger `unlock()`,
    /// preventing an infinite Face ID prompt loop after the user taps Cancel.
    private var autoUnlockPending: Bool
    /// Monotonic counter invalidated on lock/disable so stale `LAContext.evaluatePolicy`
    /// completions from an earlier lock cycle cannot mutate state or block re-authentication.
    private var lockGeneration: UInt64 = 0
    private var activeContext: LAContext?

    private enum AuthEvaluation {
        case succeeded
        case cancelled
        case failed(String)
        case superseded
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.defaultsKey)
        self.appLockEnabled = enabled
        self.isLocked = enabled
        self.autoUnlockPending = enabled
    }

    func setEnabled(_ enabled: Bool) {
        appLockEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if !enabled {
            lockGeneration &+= 1
            activeContext?.invalidate()
            activeContext = nil
            isLocked = false
            isAuthenticating = false
            authError = nil
            autoUnlockPending = false
        }
    }

    /// Verifies device authentication before turning App Lock on; returns a user-facing error
    /// message if device authentication is unavailable or fails (nil on success or user cancel).
    func enableWithAuthentication() async -> String? {
        guard !isAuthenticating else { return nil }
        switch await evaluateDeviceOwnerAuthentication(
            reason: "Verify your identity to enable Face ID / Passcode Lock.",
            failureMessage: "Authentication was not completed."
        ) {
        case .succeeded:
            setEnabled(true)
            AppHaptics.notify(.success)
            return nil
        case .cancelled, .superseded:
            return nil
        case .failed(let message):
            return message
        }
    }

    /// Verifies device authentication before turning App Lock off; keeps App Lock enabled unless authentication succeeds.
    func disableWithAuthentication() async -> Bool {
        guard appLockEnabled else { return true }
        guard !isAuthenticating else { return false }
        switch await evaluateDeviceOwnerAuthentication(
            reason: "Verify your identity to disable Face ID / Passcode Lock.",
            failureMessage: "Authentication was not completed."
        ) {
        case .succeeded:
            guard appLockEnabled else { return true }
            setEnabled(false)
            AppHaptics.notify(.success)
            return true
        case .cancelled, .failed, .superseded:
            return false
        }
    }

    func lockIfEnabled() {
        guard appLockEnabled else { return }
        lockGeneration &+= 1
        activeContext?.invalidate()
        activeContext = nil
        isLocked = true
        isAuthenticating = false
        autoUnlockPending = true
        authError = nil
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func unlockOnActiveIfNeeded() async {
        guard isLocked, autoUnlockPending else { return }
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        autoUnlockPending = false
        authError = nil

        switch await evaluateDeviceOwnerAuthentication(
            reason: "Unlock TermApp to access your SSH sessions and keys.",
            failureMessage: "Authentication failed. Tap Unlock to try again."
        ) {
        case .succeeded:
            guard appLockEnabled else { return }
            isLocked = false
            authError = nil
            AppHaptics.notify(.success)
        case .cancelled:
            guard appLockEnabled else { return }
            isLocked = true
            authError = nil
        case .failed(let message):
            guard appLockEnabled else { return }
            isLocked = true
            authError = message
        case .superseded:
            break
        }
    }

    private final class ContextBox: @unchecked Sendable {
        let context: LAContext
        init(_ context: LAContext) { self.context = context }
    }

    private func evaluateDeviceOwnerAuthentication(reason: String, failureMessage: String) async -> AuthEvaluation {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failed(Self.unavailableMessage(for: policyError))
        }

        let generation = lockGeneration
        activeContext?.invalidate()
        activeContext = context
        isAuthenticating = true
        defer {
            if activeContext === context {
                activeContext = nil
            }
            if lockGeneration == generation {
                isAuthenticating = false
            }
        }

        do {
            let success = try await Self.evaluatePolicy(ContextBox(context), reason: reason)
            guard lockGeneration == generation else { return .superseded }
            return success ? .succeeded : .failed(failureMessage)
        } catch let error as LAError {
            guard lockGeneration == generation else { return .superseded }
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            default:
                return .failed(Self.userFriendlyMessage(for: error))
            }
        } catch {
            guard lockGeneration == generation else { return .superseded }
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func evaluatePolicy(_ box: ContextBox, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private static func unavailableMessage(for error: NSError?) -> String {
        guard let laError = error as? LAError else {
            return error?.localizedDescription ?? "Device authentication is not available."
        }
        return userFriendlyMessage(for: laError)
    }

    private static func userFriendlyMessage(for error: LAError) -> String {
        switch error.code {
        case .passcodeNotSet:
            "Set a device passcode or enroll Face ID in iOS Settings to unlock TermApp."
        case .biometryNotAvailable, .biometryNotEnrolled:
            "Biometric authentication is unavailable. Use your device passcode or configure it in iOS Settings."
        case .biometryLockout:
            "Biometrics locked out. Unlock with your device passcode."
        case .authenticationFailed:
            "Authentication failed. Tap Unlock to try again."
        default:
            error.localizedDescription
        }
    }
}

private struct PrivacyBackdropView: View {
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
    }
}

/// Sleek Apple Pro frosted lock screen shown over locked scenes.
struct AppLockOverlayView: View {
    @Environment(AppLockManager.self) private var appLock
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private static let appleProAmber = TerminalTheme.appleProDark.accentColor

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ZStack {
            PrivacyBackdropView()

            VStack(spacing: 20) {
                SquircleIcon(
                    symbolName: "lock.shield.fill",
                    tint: Self.appleProAmber,
                    fillOpacity: theme.isDark ? 0.22 : 0.14,
                    rimOpacity: 0.42,
                    size: 64
                )

                VStack(spacing: 6) {
                    Text("TermApp Locked")
                        .font(.title2.bold())
                        .foregroundStyle(theme.foregroundColor)

                    Text("Authenticate to access your SSH sessions and keys.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .multilineTextAlignment(.center)
                }

                if let authError = appLock.authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    AppHaptics.impact(.light)
                    Task { await appLock.unlock() }
                } label: {
                    HStack(spacing: 8) {
                        if appLock.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Unlock")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Self.appleProAmber)
                .disabled(appLock.isAuthenticating)
            }
            .frame(maxWidth: 340)
            .padding(28)
        }
        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
    }
}

private enum PrivacyOverlayMode: Equatable {
    case hidden
    case lock
    case veil
}

private struct PrivacyOverlayContainerView: View {
    let mode: PrivacyOverlayMode

    var body: some View {
        switch mode {
        case .hidden:
            Color.clear
        case .lock:
            AppLockOverlayView()
        case .veil:
            PrivacyBackdropView()
                .accessibilityHidden(true)
        }
    }
}

/// Hosts `AppLockOverlayView` and the privacy veil in a per-scene `UIWindow` above all sheets and popovers.
@MainActor
private struct PrivacyOverlayWindowPresenter: UIViewRepresentable {
    @Environment(AppLockManager.self) private var appLock
    let mode: PrivacyOverlayMode

    final class SceneAnchorView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var appLock: AppLockManager
        private weak var hostWindow: UIWindow?
        private weak var currentScene: UIWindowScene?
        private var overlayWindow: UIWindow?
        private var hostingController: UIHostingController<AnyView>?
        private var mode: PrivacyOverlayMode = .hidden
        private var appliedMode: PrivacyOverlayMode?

        init(appLock: AppLockManager) {
            self.appLock = appLock
        }

        func updateHostWindow(_ window: UIWindow?) {
            hostWindow = window
            let targetScene = window?.windowScene
            if targetScene !== currentScene {
                destroyOverlayWindow()
                currentScene = targetScene
            }
            applyState()
        }

        func update(mode newMode: PrivacyOverlayMode) {
            mode = newMode
            applyState()
        }

        func teardown() {
            hostWindow = nil
            currentScene = nil
            destroyOverlayWindow()
        }

        private func ensureOverlayWindow(in scene: UIWindowScene) -> (UIWindow, UIHostingController<AnyView>) {
            if let overlayWindow, let hostingController {
                return (overlayWindow, hostingController)
            }
            let controller = UIHostingController(rootView: makeRootView(for: mode))
            controller.view.backgroundColor = .clear
            let window = UIWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.windowLevel = .alert + 1
            window.rootViewController = controller
            window.isHidden = true
            window.isUserInteractionEnabled = false
            self.overlayWindow = window
            self.hostingController = controller
            self.appliedMode = mode
            return (window, controller)
        }

        private func makeRootView(for mode: PrivacyOverlayMode) -> AnyView {
            AnyView(PrivacyOverlayContainerView(mode: mode).environment(appLock))
        }

        private func applyState() {
            guard let scene = currentScene else { return }
            let (window, controller) = ensureOverlayWindow(in: scene)
            if appliedMode != mode {
                appliedMode = mode
                controller.rootView = makeRootView(for: mode)
            }

            switch mode {
            case .hidden:
                let wasKey = window.isKeyWindow
                window.isUserInteractionEnabled = false
                window.isHidden = true
                if wasKey,
                   !scene.windows.contains(where: { $0.isKeyWindow && !$0.isHidden }),
                   let hostWindow {
                    hostWindow.makeKey()
                }
            case .veil:
                let wasKey = window.isKeyWindow
                window.windowLevel = .alert + 1
                window.isUserInteractionEnabled = false
                window.isHidden = false
                window.layoutIfNeeded()
                if wasKey, let hostWindow {
                    hostWindow.makeKey()
                }
            case .lock:
                window.windowLevel = .alert + 1
                window.isUserInteractionEnabled = true
                if hostWindow?.isKeyWindow == true || scene.activationState == .foregroundActive {
                    window.makeKeyAndVisible()
                } else {
                    window.isHidden = false
                }
                window.layoutIfNeeded()
            }
        }

        private func destroyOverlayWindow() {
            guard let window = overlayWindow else { return }
            let wasKey = window.isKeyWindow
            let previousHost = hostWindow
            window.isUserInteractionEnabled = false
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            overlayWindow = nil
            hostingController = nil
            appliedMode = nil
            if wasKey, let previousHost, previousHost.windowScene != nil {
                previousHost.makeKey()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appLock: appLock)
    }

    func makeUIView(context: Context) -> SceneAnchorView {
        let view = SceneAnchorView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.updateHostWindow(window)
        }
        coordinator.update(mode: mode)
        return view
    }

    func updateUIView(_ uiView: SceneAnchorView, context: Context) {
        context.coordinator.appLock = appLock
        context.coordinator.updateHostWindow(uiView.window)
        context.coordinator.update(mode: mode)
    }

    static func dismantleUIView(_ uiView: SceneAnchorView, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.teardown()
    }
}

/// Blurs scene content in the App Switcher and locks the app when entering the background if enabled.
struct PrivacyBlurModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLockManager.self) private var appLock

    private var showPrivacyVeil: Bool {
        !appLock.isLocked && scenePhase != .active && !appLock.isAuthenticating
    }

    private var overlayMode: PrivacyOverlayMode {
        if appLock.isLocked { return .lock }
        if showPrivacyVeil { return .veil }
        return .hidden
    }

    func body(content: Content) -> some View {
        content
            .background {
                PrivacyOverlayWindowPresenter(mode: overlayMode)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                switch newPhase {
                case .background:
                    let hasActiveScene = UIApplication.shared.connectedScenes
                        .contains { $0.activationState == .foregroundActive }
                    if !hasActiveScene {
                        appLock.lockIfEnabled()
                    }
                case .active:
                    if appLock.isLocked {
                        Task { @MainActor in
                            await appLock.unlockOnActiveIfNeeded()
                        }
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
    }
}
