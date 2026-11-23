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
            isLocked = false
            authError = nil
            autoUnlockPending = false
        }
    }

    /// Verifies device authentication before turning App Lock on; returns a user-facing error
    /// message if device authentication is unavailable or fails (nil on success or user cancel).
    func enableWithAuthentication() async -> String? {
        guard !isAuthenticating else { return nil }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return Self.unavailableMessage(for: policyError)
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let success = try await Self.evaluatePolicy(
                context,
                reason: "Verify your identity to enable Face ID / Passcode Lock."
            )
            if success {
                setEnabled(true)
                AppHaptics.notify(.success)
                return nil
            }
            return "Authentication was not completed."
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return nil
            default:
                return Self.userFriendlyMessage(for: error)
            }
        } catch {
            return error.localizedDescription
        }
    }

    func lockIfEnabled() {
        guard appLockEnabled else { return }
        isLocked = true
        autoUnlockPending = true
        authError = nil
    }

    func unlockOnActiveIfNeeded() async {
        guard isLocked, autoUnlockPending else { return }
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        autoUnlockPending = false

        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            authError = Self.unavailableMessage(for: policyError)
            return
        }

        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        do {
            let success = try await Self.evaluatePolicy(
                context,
                reason: "Unlock TermApp to access your SSH sessions and keys."
            )
            if success {
                isLocked = false
                authError = nil
                AppHaptics.notify(.success)
            } else {
                isLocked = true
                authError = "Authentication failed. Tap Unlock to try again."
            }
        } catch let error as LAError {
            isLocked = true
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                authError = nil
            default:
                authError = Self.userFriendlyMessage(for: error)
            }
        } catch {
            isLocked = true
            authError = error.localizedDescription
        }
    }

    private nonisolated static func evaluatePolicy(_ context: LAContext, reason: String) async throws -> Bool {
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
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

/// Sleek Apple Pro frosted lock screen shown over locked scenes.
struct AppLockOverlayView: View {
    @Environment(AppLockManager.self) private var appLock
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    private static let appleProAmber = TerminalTheme.appleProDark.accentColor

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

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

/// Blurs scene content in the App Switcher and locks the app when entering the background if enabled.
struct PrivacyBlurModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLockManager.self) private var appLock

    private var showPrivacyVeil: Bool {
        !appLock.isLocked && scenePhase != .active && !appLock.isAuthenticating
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if appLock.isLocked {
                    AppLockOverlayView()
                } else if showPrivacyVeil {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
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
