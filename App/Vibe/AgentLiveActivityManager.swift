import ActivityKit
import Foundation
import os
import Store

/// Manages Dynamic Island and Lock Screen Live Activities (`ActivityKit`) for running AI agent sessions.
@MainActor
final class AgentLiveActivityManager {
    static let shared = AgentLiveActivityManager()

    private static let logger = Logger(subsystem: "com.peculiarengineer.termapp", category: "live-activity")
    private static let minimumUpdateInterval: TimeInterval = 0.75
    private static let urgentUpdateInterval: TimeInterval = 0.25

    private var lastSentContentState: [UUID: AgentActivityAttributes.ContentState] = [:]
    private var lastUpdateTimestamp: [UUID: Date] = [:]
    private var pendingContentState: [UUID: AgentActivityAttributes.ContentState] = [:]
    private var pendingUpdateTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Starts a new Live Activity for `live` or schedules a debounced update if one already exists.
    func startOrUpdate(for live: LiveSession) {
        guard let attributes = Self.makeAttributes(for: live) else {
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let state = Self.makeContentState(for: live, projectName: attributes.projectName)
        let sessionID = live.id

        if let existing = activeActivity(for: sessionID) {
            if let lastSent = lastSentContentState[sessionID],
               lastSent.status == state.status,
               lastSent.statusMessage == state.statusMessage {
                return
            }

            let now = Date()
            let requiredInterval = (state.status == "approval" || state.status == "done")
                ? Self.urgentUpdateInterval
                : Self.minimumUpdateInterval

            if let lastAt = lastUpdateTimestamp[sessionID] {
                let elapsed = now.timeIntervalSince(lastAt)
                if elapsed < requiredInterval {
                    scheduleDebouncedUpdate(
                        sessionID: sessionID,
                        activityID: existing.id,
                        state: state,
                        delay: requiredInterval - elapsed
                    )
                    return
                }
            }

            pendingUpdateTasks[sessionID]?.cancel()
            pendingUpdateTasks[sessionID] = nil
            pendingContentState[sessionID] = nil
            dispatchImmediateUpdate(sessionID: sessionID, activityID: existing.id, state: state, now: now)
            return
        }

        pendingUpdateTasks[sessionID]?.cancel()
        pendingUpdateTasks[sessionID] = nil
        pendingContentState[sessionID] = nil

        do {
            _ = try Activity<AgentActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastSentContentState[sessionID] = state
            lastUpdateTimestamp[sessionID] = Date()
        } catch {
            Self.logger.error("Failed to start Live Activity for session \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Immediately ends and dismisses any Live Activity matching `sessionID`.
    func end(sessionID: UUID) {
        pendingUpdateTasks[sessionID]?.cancel()
        pendingUpdateTasks[sessionID] = nil
        pendingContentState[sessionID] = nil
        lastSentContentState[sessionID] = nil
        lastUpdateTimestamp[sessionID] = nil

        let hasMatchingActivity = Activity<AgentActivityAttributes>.activities.contains {
            $0.attributes.sessionID == sessionID
        }
        guard hasMatchingActivity else { return }

        Task {
            await Self.performEnd(sessionID: sessionID)
        }
    }

    /// Ends orphaned Live Activities from prior killed processes whose session IDs are not in `liveIDs`.
    func endStaleActivities(keeping liveIDs: Set<UUID>) {
        let staleSessionIDs = Set(
            Activity<AgentActivityAttributes>.activities
                .map(\.attributes.sessionID)
                .filter { !liveIDs.contains($0) }
        )
        for sessionID in staleSessionIDs {
            pendingUpdateTasks[sessionID]?.cancel()
            pendingUpdateTasks[sessionID] = nil
            pendingContentState[sessionID] = nil
            lastSentContentState[sessionID] = nil
            lastUpdateTimestamp[sessionID] = nil
        }

        guard !staleSessionIDs.isEmpty else { return }
        Task {
            await Self.performEndStale(keeping: liveIDs)
        }
    }

    // MARK: - Attribute & State Builders

    static func makeAttributes(for live: LiveSession) -> AgentActivityAttributes? {
        guard let ctx = live.aiAgentContext else { return nil }
        let hostLabel = resolveHostLabel(title: live.title, agentName: ctx.agent.name)
        let projectName = resolveProjectName(from: ctx)
        return AgentActivityAttributes(
            sessionID: live.id,
            hostID: live.hostID,
            hostLabel: hostLabel,
            agentName: ctx.agent.name,
            agentSlug: ctx.agent.slug,
            projectName: projectName,
            sessionName: ctx.sessionName
        )
    }

    static func makeContentState(
        for live: LiveSession,
        projectName: String,
        now: Date = .now
    ) -> AgentActivityAttributes.ContentState {
        let status: String
        let statusMessage: String

        switch live.agentActivityState {
        case .running:
            status = WidgetAgentStatus.running.rawValue
            statusMessage = "Running in \(projectName)"
        case .waitingForApproval(let prompt):
            status = WidgetAgentStatus.approval.rawValue
            let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            statusMessage = trimmed.isEmpty ? "Waiting for your approval" : trimmed
        case .completed:
            status = WidgetAgentStatus.done.rawValue
            statusMessage = "Ready for next prompt"
        case .idle:
            status = WidgetAgentStatus.idle.rawValue
            switch live.connectionStatus {
            case .connected:
                statusMessage = "Connected · \(projectName)"
            case .reconnecting:
                statusMessage = "Reconnecting…"
            case .disconnected:
                statusMessage = "Disconnected"
            }
        }

        return AgentActivityAttributes.ContentState(
            status: status,
            statusMessage: statusMessage,
            updatedAt: now
        )
    }

    static func resolveHostLabel(title: String, agentName: String) -> String {
        let agentPrefix = "\(agentName) · "
        let raw: String
        if title.hasPrefix(agentPrefix) {
            raw = String(title.dropFirst(agentPrefix.count))
        } else {
            raw = title
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Host" : trimmed
    }

    static func resolveProjectName(from context: AIAgentLaunchContext) -> String {
        let isManaged = context.sessionName.hasPrefix(TMuxSessionHelper.sessionPrefix)
        let trimmedDir = context.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isManaged && (trimmedDir.isEmpty || trimmedDir == "~" || trimmedDir == "~/") {
            return context.sessionName
        }
        return TMuxSessionHelper.projectSlug(from: context.workingDirectory)
    }

    // MARK: - Private Helpers

    private func activeActivity(for sessionID: UUID) -> Activity<AgentActivityAttributes>? {
        Activity<AgentActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID
                && $0.activityState != .ended
                && $0.activityState != .dismissed
        }
    }

    private func scheduleDebouncedUpdate(
        sessionID: UUID,
        activityID: String,
        state: AgentActivityAttributes.ContentState,
        delay: TimeInterval
    ) {
        pendingContentState[sessionID] = state
        pendingUpdateTasks[sessionID]?.cancel()
        let sleepNanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)

        pendingUpdateTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingUpdateTasks[sessionID] = nil
            guard let latestState = self.pendingContentState.removeValue(forKey: sessionID) else { return }
            if let lastSent = self.lastSentContentState[sessionID],
               lastSent.status == latestState.status,
               lastSent.statusMessage == latestState.statusMessage {
                return
            }
            self.dispatchImmediateUpdate(sessionID: sessionID, activityID: activityID, state: latestState, now: Date())
        }
    }

    private func dispatchImmediateUpdate(
        sessionID: UUID,
        activityID: String,
        state: AgentActivityAttributes.ContentState,
        now: Date
    ) {
        lastSentContentState[sessionID] = state
        lastUpdateTimestamp[sessionID] = now
        Task {
            await Self.performUpdate(activityID: activityID, state: state)
        }
    }

    private nonisolated static func performUpdate(
        activityID: String,
        state: AgentActivityAttributes.ContentState
    ) async {
        guard let activity = Activity<AgentActivityAttributes>.activities.first(where: {
            $0.id == activityID
                && $0.activityState != .ended
                && $0.activityState != .dismissed
        }) else {
            return
        }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func performEnd(sessionID: UUID) async {
        for activity in Activity<AgentActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func performEndStale(keeping liveIDs: Set<UUID>) async {
        for activity in Activity<AgentActivityAttributes>.activities where !liveIDs.contains(activity.attributes.sessionID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
