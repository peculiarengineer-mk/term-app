import Foundation
import os
import SwiftUI
import UIKit
import UserNotifications
import Store

extension Notification.Name {
    static let termFocusAgentSession = Notification.Name("TermAppFocusAgentSession")
}

/// Dedicated non-isolated delegate proxy so UserNotifications callbacks on background queues
/// never hit Swift 6 `@MainActor` / `async` ObjC bridging thunk executor checks.
private final class NotificationCenterDelegateProxy: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(AgentNotificationManager.requestIdentifierPrefix) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawID = response.notification.request.content.userInfo[AgentNotificationManager.sessionIDKey] as? String
        if let rawID, let sessionID = UUID(uuidString: rawID) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentNotificationManager.shared.handleNotificationTap(sessionID: sessionID)
                }
            }
        }
        completionHandler()
    }
}

/// Manages local notifications and haptics when AI coding agents wait for approval or finish responding.
@MainActor
final class AgentNotificationManager {
    static let shared = AgentNotificationManager()
    static let notificationsEnabledKey = "agents.notificationsEnabled"
    nonisolated static let requestIdentifierPrefix = "termapp.agent."
    nonisolated static let sessionIDKey = "sessionID"
    private static let logger = Logger(subsystem: "com.peculiarengineer.termapp", category: "notifications")

    private let delegateProxy = NotificationCenterDelegateProxy()
    private let notificationCenter: NotificationCenter
    private var isDelegateConfigured = false
    private var isRequestingAuthorization = false
    private(set) var pendingFocusSessionID: UUID?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
    }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func configureDelegate() {
        guard !isDelegateConfigured else { return }
        isDelegateConfigured = true
        UNUserNotificationCenter.current().delegate = delegateProxy
    }

    /// Requests local notification authorization once if `notificationsEnabled` is on and permission is undetermined.
    func requestAuthorizationIfNeeded() {
        guard isEnabled, !isRequestingAuthorization else { return }
        configureDelegate()
        isRequestingAuthorization = true

        Task { @MainActor [weak self] in
            defer { self?.isRequestingAuthorization = false }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard let self, self.isEnabled, settings.authorizationStatus == .notDetermined else { return }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Self.logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fires haptics when active/visible and schedules a local notification when backgrounded or on another tab.
    func notifyIfNeeded(
        sessionTitle: String,
        agentName: String,
        state: AgentActivityState,
        isActiveVisibleTab: Bool,
        sessionID: UUID? = nil
    ) {
        guard isEnabled else { return }

        let resolvedAgent = agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "AI Agent" : agentName
        let payload: (title: String, subtitle: String?, body: String, haptic: UINotificationFeedbackGenerator.FeedbackType, suffix: String)?

        switch state {
        case .waitingForApproval(let prompt):
            let cleanPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = cleanPrompt.isEmpty ? "Waiting for your approval to continue." : cleanPrompt
            payload = (
                title: "\(resolvedAgent) Needs Approval",
                subtitle: sessionTitle == resolvedAgent ? nil : sessionTitle,
                body: body,
                haptic: .warning,
                suffix: "waiting"
            )
        case .completed:
            payload = (
                title: "\(resolvedAgent) Finished",
                subtitle: sessionTitle == resolvedAgent ? nil : sessionTitle,
                body: "Ready for your next prompt.",
                haptic: .success,
                suffix: "completed"
            )
        case .idle, .running:
            payload = nil
        }

        guard let payload else { return }

        let isAppActive = UIApplication.shared.applicationState == .active
        if isAppActive {
            AppHaptics.notify(payload.haptic)
        }
        if isAppActive && isActiveVisibleTab {
            return
        }

        configureDelegate()
        let idToken = sessionID?.uuidString ?? UUID().uuidString
        let requestID = "\(Self.requestIdentifierPrefix)\(idToken).\(payload.suffix)"
        let sessionIDString = sessionID?.uuidString

        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard let self,
                  self.isEnabled,
                  settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = payload.title
            if let subtitle = payload.subtitle {
                content.subtitle = subtitle
            }
            content.body = payload.body
            content.sound = .default
            if let sessionIDString {
                content.userInfo = [Self.sessionIDKey: sessionIDString]
                content.threadIdentifier = sessionIDString
            }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
            let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                Self.logger.error("Failed to schedule agent notification \(requestID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Records a tapped notification's session ID for deferred focus (e.g. while locked or launching)
    /// and notifies any mounted `SessionTabsView`.
    func handleNotificationTap(sessionID: UUID) {
        pendingFocusSessionID = sessionID
        notificationCenter.post(
            name: .termFocusAgentSession,
            object: nil,
            userInfo: [Self.sessionIDKey: sessionID]
        )
    }

    /// Returns and clears any pending session focus request from a notification tap.
    func consumePendingFocusSessionID() -> UUID? {
        defer { pendingFocusSessionID = nil }
        return pendingFocusSessionID
    }
}

/// Compact live AI agent state indicator rendered on tab chips, session rows, and the ActiveSessionPill.
struct AgentActivityBadge: View {
    let state: AgentActivityState
    var showLabel: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private static let runningCyan = Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.runningCyan)
                    .frame(width: 7, height: 7)
                    .scaleEffect(isPulsing ? 1.25 : 0.9)
                    .opacity(isPulsing ? 0.55 : 1.0)
                    .shadow(color: Self.runningCyan.opacity(0.65), radius: 3)

                if showLabel {
                    Text("Running")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.runningCyan)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onDisappear {
                isPulsing = false
            }
            .accessibilityLabel("Agent running")

        case .waitingForApproval:
            HStack(spacing: 3) {
                Image(systemName: "bell.fill")
                    .font(.system(size: showLabel ? 10 : 11, weight: .bold))
                if showLabel {
                    Text("Approval")
                        .font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(AgentVisuals.appleProAmber)
            .padding(.horizontal, showLabel ? 6 : 0)
            .padding(.vertical, showLabel ? 2 : 0)
            .background(
                showLabel ? AgentVisuals.appleProAmber.opacity(0.16) : Color.clear,
                in: Capsule()
            )
            .accessibilityLabel("Agent waiting for approval")

        case .completed:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: showLabel ? 10 : 11, weight: .bold))
                if showLabel {
                    Text("Done")
                        .font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(AgentVisuals.activeGreen)
            .padding(.horizontal, showLabel ? 6 : 0)
            .padding(.vertical, showLabel ? 2 : 0)
            .background(
                showLabel ? AgentVisuals.activeGreen.opacity(0.16) : Color.clear,
                in: Capsule()
            )
            .accessibilityLabel("Agent finished")
        }
    }
}
