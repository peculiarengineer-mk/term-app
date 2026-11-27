import Foundation
import Store
import WidgetKit

/// Synchronizes SwiftData hosts, live AI sessions, and cached tmux sessions to App Group storage for WidgetKit & AppIntents.
@MainActor
enum WidgetSyncCoordinator {
    static let lastConnectedStorageKey = "termapp.widget.hostLastConnected.v1"

    /// Records the most recent connection timestamp for `hostID` and refreshes existing host snapshots.
    static func recordHostConnected(
        hostID: UUID,
        at date: Date = .now,
        defaults: UserDefaults = WidgetSnapshotStore.sharedDefaults(),
        reloadTimelines: Bool = true
    ) {
        var dates = loadLastConnectedDates(defaults: defaults)
        dates[hostID] = date
        saveLastConnectedDates(dates, defaults: defaults)

        var existing = WidgetSnapshotStore.loadHosts(defaults: defaults)
        guard !existing.isEmpty else { return }

        var updated = false
        for index in existing.indices where existing[index].id == hostID {
            existing[index].lastConnectedAt = date
            updated = true
        }
        guard updated else { return }

        let sorted = sortHostSnapshots(existing)
        WidgetSnapshotStore.saveHosts(sorted, defaults: defaults)
        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Removes persisted connection metadata for a deleted host.
    static func removeHostMetadata(
        for hostID: UUID,
        defaults: UserDefaults = WidgetSnapshotStore.sharedDefaults()
    ) {
        var dates = loadLastConnectedDates(defaults: defaults)
        guard dates.removeValue(forKey: hostID) != nil else { return }
        saveLastConnectedDates(dates, defaults: defaults)
    }

    /// Writes `[WidgetHostSnapshot]` sorted by most-recently connected then label, reloading WidgetKit timelines when changed.
    static func syncHosts(
        _ hosts: [Host],
        defaults: UserDefaults = WidgetSnapshotStore.sharedDefaults(),
        reloadTimelines: Bool = true
    ) {
        let validHostIDs = Set(hosts.map(\.id))
        var dates = loadLastConnectedDates(defaults: defaults)
        let originalCount = dates.count
        dates = dates.filter { validHostIDs.contains($0.key) }
        if dates.count != originalCount {
            saveLastConnectedDates(dates, defaults: defaults)
        }

        let snapshots = buildHostSnapshots(from: hosts, lastConnectedDates: dates)
        let hasStoredData = defaults.data(forKey: WidgetSnapshotStore.hostsStorageKey) != nil
        let existing = hasStoredData ? WidgetSnapshotStore.loadHosts(defaults: defaults) : []

        guard !hasStoredData || existing != snapshots else { return }
        WidgetSnapshotStore.saveHosts(snapshots, defaults: defaults)
        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Writes `[WidgetAgentSnapshot]` combining live AI sessions and cached remote tmux sessions, reloading timelines when changed.
    static func syncAgents(
        liveSessions: [LiveSession],
        cacheDefaults: UserDefaults = .standard,
        widgetDefaults: UserDefaults = WidgetSnapshotStore.sharedDefaults(),
        reloadTimelines: Bool = true
    ) {
        let cached = AISessionCacheStore.load(defaults: cacheDefaults)
        let hasStoredData = widgetDefaults.data(forKey: WidgetSnapshotStore.agentsStorageKey) != nil
        let existing = hasStoredData ? WidgetSnapshotStore.loadAgents(defaults: widgetDefaults) : []
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let snapshots = buildAgentSnapshots(
            liveSessions: liveSessions,
            cachedSessions: cached,
            existingSnapshotsByID: existingByID
        )

        guard !hasStoredData || existing != snapshots else { return }
        WidgetSnapshotStore.saveAgents(snapshots, defaults: widgetDefaults)
        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Pure Snapshot Builders

    static func buildHostSnapshots(
        from hosts: [Host],
        lastConnectedDates: [UUID: Date]
    ) -> [WidgetHostSnapshot] {
        let unsorted = hosts.map { host in
            WidgetHostSnapshot(
                id: host.id,
                label: host.label,
                hostname: host.hostname,
                username: host.username,
                tags: host.tags,
                lastConnectedAt: lastConnectedDates[host.id],
                source: host.source
            )
        }
        return sortHostSnapshots(unsorted)
    }

    static func sortHostSnapshots(_ snapshots: [WidgetHostSnapshot]) -> [WidgetHostSnapshot] {
        snapshots.sorted { lhs, rhs in
            switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
            case (.some(let lDate), .some(let rDate)) where lDate != rDate:
                return lDate > rDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let labelOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func buildAgentSnapshots(
        liveSessions: [LiveSession],
        cachedSessions: [CachedAISession],
        existingSnapshotsByID: [String: WidgetAgentSnapshot] = [:],
        now: Date = .now
    ) -> [WidgetAgentSnapshot] {
        var seenIDs = Set<String>()
        var results: [WidgetAgentSnapshot] = []

        for live in liveSessions {
            guard let ctx = live.aiAgentContext else { continue }
            let key = "\(live.hostID.uuidString):\(ctx.sessionName)"
            guard seenIDs.insert(key).inserted else { continue }

            let hostLabel = AgentLiveActivityManager.resolveHostLabel(title: live.title, agentName: ctx.agent.name)
            let projectSlug = AgentLiveActivityManager.resolveProjectName(from: ctx)
            let (status, promptSnippet) = mappedStatus(for: live.agentActivityState)

            let previous = existingSnapshotsByID[key]
            let isUnchangedState = previous != nil
                && previous?.sessionID == live.id
                && previous?.hostLabel == hostLabel
                && previous?.agentSlug == ctx.agent.slug
                && previous?.agentName == ctx.agent.name
                && previous?.projectSlug == projectSlug
                && previous?.status == status
                && previous?.promptSnippet == promptSnippet
            let updatedAt = isUnchangedState ? (previous?.updatedAt ?? now) : now

            results.append(
                WidgetAgentSnapshot(
                    sessionID: live.id,
                    hostID: live.hostID,
                    hostLabel: hostLabel,
                    sessionName: ctx.sessionName,
                    agentSlug: ctx.agent.slug,
                    agentName: ctx.agent.name,
                    projectSlug: projectSlug,
                    status: status,
                    promptSnippet: promptSnippet,
                    updatedAt: updatedAt
                )
            )
        }

        for cached in cachedSessions where cached.isAISession {
            let key = cached.id
            guard seenIDs.insert(key).inserted else { continue }

            let descriptor = AgentVisuals.agentDescriptor(forSlug: cached.agentSlug)
            let resolvedProject = cached.projectSlug.isEmpty ? cached.sessionName : cached.projectSlug
            results.append(
                WidgetAgentSnapshot(
                    sessionID: nil,
                    hostID: cached.hostID,
                    hostLabel: cached.hostLabel,
                    sessionName: cached.sessionName,
                    agentSlug: cached.agentSlug,
                    agentName: descriptor.name,
                    projectSlug: resolvedProject,
                    status: .idle,
                    promptSnippet: nil,
                    updatedAt: cached.lastSeenAt
                )
            )
        }

        return results.sorted { lhs, rhs in
            let lPriority = sortPriority(for: lhs.status)
            let rPriority = sortPriority(for: rhs.status)
            if lPriority != rPriority {
                return lPriority < rPriority
            }

            let lIsLive = lhs.sessionID != nil
            let rIsLive = rhs.sessionID != nil
            if lIsLive != rIsLive {
                return lIsLive && !rIsLive
            }

            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }

            let hostOrder = lhs.hostLabel.localizedCaseInsensitiveCompare(rhs.hostLabel)
            if hostOrder != .orderedSame {
                return hostOrder == .orderedAscending
            }
            return lhs.sessionName.localizedCaseInsensitiveCompare(rhs.sessionName) == .orderedAscending
        }
    }

    // MARK: - Private Helpers

    private static func mappedStatus(for state: AgentActivityState) -> (WidgetAgentStatus, String?) {
        switch state {
        case .running:
            return (.running, nil)
        case .waitingForApproval(let prompt):
            let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (.approval, trimmed.isEmpty ? nil : trimmed)
        case .completed:
            return (.done, nil)
        case .idle:
            return (.idle, nil)
        }
    }

    private static func sortPriority(for status: WidgetAgentStatus) -> Int {
        switch status {
        case .approval: 0
        case .running: 1
        case .done: 2
        case .idle: 3
        }
    }

    static func loadLastConnectedDates(defaults: UserDefaults = WidgetSnapshotStore.sharedDefaults()) -> [UUID: Date] {
        guard let data = defaults.data(forKey: lastConnectedStorageKey),
              let rawMap = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        var result: [UUID: Date] = [:]
        for (key, date) in rawMap {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = date
            }
        }
        return result
    }

    private static func saveLastConnectedDates(_ dates: [UUID: Date], defaults: UserDefaults) {
        let rawMap = Dictionary(uniqueKeysWithValues: dates.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(rawMap) else { return }
        defaults.set(data, forKey: lastConnectedStorageKey)
    }
}
