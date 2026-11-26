import Foundation
import SSHKit
import Store
import XCTest
@testable import TermApp

@MainActor
final class WidgetsAndDeepLinkTests: XCTestCase {
    private func makeIsolatedDefaults(prefix: String) -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "com.peculiarengineer.termapp.tests.\(prefix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - DeepLinkRouter

    func testDeepLinkRouterEnqueueConsumeAndValidation() throws {
        let router = DeepLinkRouter()
        XCTAssertNil(router.pendingLink)

        let hostID = UUID()
        let connectURL = try XCTUnwrap(URL(string: "termapp://host/\(hostID.uuidString)"))
        XCTAssertTrue(router.enqueue(url: connectURL))
        XCTAssertEqual(router.pendingLink, .connectHost(hostID: hostID))

        // Invalid URLs return false and do not clobber the existing queued deep link.
        let invalidURL = try XCTUnwrap(URL(string: "https://example.com/host/\(hostID.uuidString)"))
        XCTAssertFalse(router.enqueue(url: invalidURL))
        XCTAssertEqual(router.pendingLink, .connectHost(hostID: hostID))

        // Newer valid deep link replaces pending link and consume clears it once read.
        let agentLink = TermAppDeepLink.launchAgent(
            hostID: hostID,
            agentSlug: "claude",
            sessionName: "termapp-ai-claude-repo"
        )
        router.enqueue(agentLink)
        XCTAssertEqual(router.consumePendingLink(), agentLink)
        XCTAssertNil(router.pendingLink)
        XCTAssertNil(router.consumePendingLink())
    }

    func testDeepLinkRouterSharedPreservesLinkUntilConsumedAfterUnlock() throws {
        let (defaults, cleanup) = makeIsolatedDefaults(prefix: "applock-deeplink")
        defer {
            cleanup()
            _ = DeepLinkRouter.shared.consumePendingLink()
        }
        _ = DeepLinkRouter.shared.consumePendingLink()

        defaults.set(true, forKey: AppLockManager.defaultsKey)
        let appLock = AppLockManager(defaults: defaults)
        XCTAssertTrue(appLock.isLocked)

        let sessionID = UUID()
        DeepLinkRouter.shared.enqueue(.focusSession(sessionID: sessionID))

        // While locked, UI consumers must not drain the pending deep link.
        let consumedWhileLocked: TermAppDeepLink? = appLock.isLocked ? nil : DeepLinkRouter.shared.consumePendingLink()
        XCTAssertNil(consumedWhileLocked)
        XCTAssertEqual(DeepLinkRouter.shared.pendingLink, .focusSession(sessionID: sessionID))

        // Once unlocked, the pending deep link is still intact and consumed once.
        appLock.setEnabled(false)
        XCTAssertFalse(appLock.isLocked)
        let consumedAfterUnlock = appLock.isLocked ? nil : DeepLinkRouter.shared.consumePendingLink()
        XCTAssertEqual(consumedAfterUnlock, .focusSession(sessionID: sessionID))
        XCTAssertNil(DeepLinkRouter.shared.pendingLink)
    }

    // MARK: - WidgetSyncCoordinator

    func testWidgetSyncHostsSortsByRecentConnectionThenLabel() {
        let (defaults, cleanup) = makeIsolatedDefaults(prefix: "widget-hosts")
        defer { cleanup() }

        let alpha = Host(label: "Alpha", hostname: "alpha.internal", username: "ops", tags: ["prod"])
        let beta = Host(label: "Beta", hostname: "beta.internal", username: "dev")
        let gamma = Host(label: "", hostname: "gamma.local", username: "keith")
        let zeta = Host(label: "Zeta", hostname: "zeta.internal", username: "root")

        let older = Date(timeIntervalSince1970: 1_750_000_100)
        let newer = Date(timeIntervalSince1970: 1_750_000_500)
        WidgetSyncCoordinator.recordHostConnected(hostID: alpha.id, at: older, defaults: defaults, reloadTimelines: false)
        WidgetSyncCoordinator.recordHostConnected(hostID: zeta.id, at: newer, defaults: defaults, reloadTimelines: false)

        WidgetSyncCoordinator.syncHosts([gamma, beta, alpha, zeta], defaults: defaults, reloadTimelines: false)

        let synced = WidgetSnapshotStore.loadHosts(defaults: defaults)
        XCTAssertEqual(synced.map(\.id), [zeta.id, alpha.id, beta.id, gamma.id])
        XCTAssertEqual(synced[0].lastConnectedAt, newer)
        XCTAssertEqual(synced[1].lastConnectedAt, older)
        XCTAssertNil(synced[2].lastConnectedAt)
        XCTAssertEqual(synced[3].displayName, "gamma.local")

        // Deleting a host removes its connection timestamp and host snapshot.
        WidgetSyncCoordinator.removeHostMetadata(for: zeta.id, defaults: defaults)
        WidgetSyncCoordinator.syncHosts([gamma, beta, alpha], defaults: defaults, reloadTimelines: false)
        let afterDelete = WidgetSnapshotStore.loadHosts(defaults: defaults)
        XCTAssertEqual(afterDelete.map(\.id), [alpha.id, beta.id, gamma.id])
        XCTAssertNil(WidgetSyncCoordinator.loadLastConnectedDates(defaults: defaults)[zeta.id])
    }

    func testWidgetSyncAgentsPrioritizesApprovalAndDeduplicatesWithSessionManager() {
        let (cacheDefaults, cleanupCache) = makeIsolatedDefaults(prefix: "widget-agent-cache")
        let (widgetDefaults, cleanupWidget) = makeIsolatedDefaults(prefix: "widget-agent-store")
        defer {
            cleanupCache()
            cleanupWidget()
        }

        let hostA = UUID()
        let hostB = UUID()

        // Cached detached session on Host B.
        let detachedCached = CachedAISession(
            hostID: hostB,
            hostLabel: "Dev Box",
            sessionName: "termapp-ai-aider-docs",
            agentSlug: "aider",
            projectSlug: "docs",
            currentPath: "~/docs",
            lastSeenAt: Date(timeIntervalSince1970: 1_750_000_100),
            wasOpenInApp: false
        )
        AISessionCacheStore.upsert(detachedCached, defaults: cacheDefaults)

        let manager = SessionManager(cacheDefaults: cacheDefaults, widgetDefaults: widgetDefaults)

        let codex = AIAgentDescriptor(builtIn: .codex)
        let codexSession = manager.open(
            hostID: hostA,
            title: "Codex · Prod Box",
            session: WidgetStubSession(),
            bridge: SessionBridge(session: WidgetStubSession()),
            aiAgentContext: AIAgentLaunchContext(
                agent: codex,
                sessionName: "termapp-ai-codex-api",
                workingDirectory: "~/api",
                hostID: hostA
            )
        )
        codexSession.agentActivityState = .running

        let claude = AIAgentDescriptor(builtIn: .claude)
        let claudeSession = manager.open(
            hostID: hostA,
            title: "Claude Code · Prod Box",
            session: WidgetStubSession(),
            bridge: SessionBridge(session: WidgetStubSession()),
            aiAgentContext: AIAgentLaunchContext(
                agent: claude,
                sessionName: "termapp-ai-claude-web",
                workingDirectory: "~/web",
                hostID: hostA
            )
        )
        claudeSession.agentActivityState = .waitingForApproval(prompt: "Apply changes? [y/N]")

        let synced = WidgetSnapshotStore.loadAgents(defaults: widgetDefaults)
        XCTAssertEqual(synced.count, 3)
        // Approval-waiting session comes first, then running, then detached idle.
        XCTAssertEqual(synced[0].sessionID, claudeSession.id)
        XCTAssertEqual(synced[0].status, .approval)
        XCTAssertEqual(synced[0].promptSnippet, "Apply changes? [y/N]")
        XCTAssertEqual(synced[0].hostLabel, "Prod Box")
        XCTAssertEqual(synced[0].projectSlug, "web")

        XCTAssertEqual(synced[1].sessionID, codexSession.id)
        XCTAssertEqual(synced[1].status, .running)

        XCTAssertNil(synced[2].sessionID)
        XCTAssertEqual(synced[2].sessionName, "termapp-ai-aider-docs")
        XCTAssertEqual(synced[2].agentName, "Aider")
        XCTAssertEqual(synced[2].status, .idle)

        // Closing live claude session demotes it to cached idle (no duplicate entries).
        manager.close(claudeSession.id)
        let afterClose = WidgetSnapshotStore.loadAgents(defaults: widgetDefaults)
        XCTAssertEqual(afterClose.count, 3)
        XCTAssertEqual(afterClose[0].sessionID, codexSession.id)
        XCTAssertEqual(afterClose[0].status, .running)
        let closedEntry = afterClose.first { $0.sessionName == "termapp-ai-claude-web" }
        XCTAssertNil(closedEntry?.sessionID)
        XCTAssertEqual(closedEntry?.status, .idle)
    }

    // MARK: - AgentActivityAttributes & LiveActivityManager Helpers

    func testAgentLiveActivityAttributeAndStateMapping() throws {
        let hostID = UUID()
        let stub = WidgetStubSession()
        let plainLive = LiveSession(
            hostID: hostID,
            title: "Plain Shell",
            session: stub,
            bridge: SessionBridge(session: stub)
        )
        XCTAssertNil(AgentLiveActivityManager.makeAttributes(for: plainLive))

        let agy = AIAgentDescriptor(builtIn: .agy)
        let aiLive = LiveSession(
            hostID: hostID,
            title: "Antigravity · Mac Studio",
            session: stub,
            bridge: SessionBridge(session: stub),
            aiAgentContext: AIAgentLaunchContext(
                agent: agy,
                sessionName: "termapp-ai-agy-term-app",
                workingDirectory: "~/projects/term-app",
                hostID: hostID
            )
        )

        let attrs = try XCTUnwrap(AgentLiveActivityManager.makeAttributes(for: aiLive))
        XCTAssertEqual(attrs.sessionID, aiLive.id)
        XCTAssertEqual(attrs.hostID, hostID)
        XCTAssertEqual(attrs.hostLabel, "Mac Studio")
        XCTAssertEqual(attrs.agentName, "Antigravity")
        XCTAssertEqual(attrs.agentSlug, "agy")
        XCTAssertEqual(attrs.projectName, "term-app")
        XCTAssertEqual(attrs.sessionName, "termapp-ai-agy-term-app")

        aiLive.agentActivityState = .running
        let runningState = AgentLiveActivityManager.makeContentState(for: aiLive, projectName: attrs.projectName)
        XCTAssertEqual(runningState.status, "running")

        aiLive.agentActivityState = .waitingForApproval(prompt: "Run rm -rf build? [y/N]")
        let approvalState = AgentLiveActivityManager.makeContentState(for: aiLive, projectName: attrs.projectName)
        XCTAssertEqual(approvalState.status, "approval")
        XCTAssertEqual(approvalState.statusMessage, "Run rm -rf build? [y/N]")

        aiLive.agentActivityState = .completed
        let doneState = AgentLiveActivityManager.makeContentState(for: aiLive, projectName: attrs.projectName)
        XCTAssertEqual(doneState.status, "done")

        let encoded = try JSONEncoder().encode(approvalState)
        let decoded = try JSONDecoder().decode(AgentActivityAttributes.ContentState.self, from: encoded)
        XCTAssertEqual(decoded, approvalState)
    }

    // MARK: - App Intents

    func testAppIntentsQueryAndEnqueueDeepLinks() {
        let (defaults, cleanup) = makeIsolatedDefaults(prefix: "appintents")
        defer { cleanup() }

        let host1 = WidgetHostSnapshot(
            id: UUID(),
            label: "Prod API",
            hostname: "api.example.com",
            username: "deploy",
            tags: ["production", "eu"]
        )
        let host2 = WidgetHostSnapshot(
            id: UUID(),
            label: "Home Mac",
            hostname: "mac.local",
            username: "keith",
            tags: ["homelab"]
        )
        WidgetSnapshotStore.saveHosts([host1, host2], defaults: defaults)

        XCTAssertEqual(HostEntityQuery.suggestedEntities(defaults: defaults).map(\.id), [host1.id, host2.id])
        XCTAssertEqual(HostEntityQuery.entities(matching: "eu", defaults: defaults).map(\.id), [host1.id])
        XCTAssertEqual(HostEntityQuery.entities(matching: "mac.local", defaults: defaults).map(\.id), [host2.id])
        XCTAssertEqual(HostEntityQuery.entities(for: [host2.id], defaults: defaults).map(\.id), [host2.id])

        XCTAssertEqual(
            Set(AIAgentAppEnum.allCases.map(\.rawValue)),
            Set(BuiltInAIAgent.allCases.map(\.rawValue))
        )

        let router = DeepLinkRouter()
        let entity = HostEntity(snapshot: host1)

        ConnectHostIntent(host: entity).enqueue(into: router)
        XCTAssertEqual(router.consumePendingLink(), .connectHost(hostID: host1.id))

        LaunchAIAgentIntent(agent: .codex, host: entity).enqueue(into: router)
        XCTAssertEqual(
            router.consumePendingLink(),
            .launchAgent(hostID: host1.id, agentSlug: "codex", sessionName: nil)
        )

        // ResumeAgentIntent falls back to .openAgentsTab when no session was open.
        ResumeAgentIntent().enqueue(into: router, cacheDefaults: defaults)
        XCTAssertEqual(router.consumePendingLink(), .openAgentsTab)

        // With an open cached session, ResumeAgentIntent targets that exact host & session.
        let cached = CachedAISession(
            hostID: host2.id,
            hostLabel: "Home Mac",
            sessionName: "termapp-ai-claude-repo",
            agentSlug: "claude",
            projectSlug: "repo",
            wasOpenInApp: true
        )
        AISessionCacheStore.upsert(cached, defaults: defaults)
        ResumeAgentIntent().enqueue(into: router, cacheDefaults: defaults)
        XCTAssertEqual(
            router.consumePendingLink(),
            .launchAgent(hostID: host2.id, agentSlug: "claude", sessionName: "termapp-ai-claude-repo")
        )
    }
}

private final class WidgetStubSession: Session, @unchecked Sendable {
    let output: AsyncStream<Data> = AsyncStream { _ in }
    let state: AsyncStream<SessionState> = AsyncStream { _ in }

    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {}
}
