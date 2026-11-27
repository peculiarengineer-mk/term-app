import Foundation
import SSHKit
import Store
import SwiftUI
import XCTest
@testable import TermApp

@MainActor
final class SessionPersistenceTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "com.peculiarengineer.termapp.tests.sessioncache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testSessionManagerOpenUpsertsTmuxAISessionAndSurvivesRestart() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        let manager = SessionManager(cacheDefaults: defaults)
        XCTAssertNil(manager.resumableAISession)
        XCTAssertEqual(manager.cacheRevision, 0)

        let claude = AIAgentDescriptor(builtIn: .claude)
        let context = AIAgentLaunchContext(
            agent: claude,
            sessionName: "termapp-ai-claude-term-app",
            workingDirectory: "~/projects/term-app",
            hostID: hostID,
            isTmuxBacked: true
        )
        let session = StubSession()
        let bridge = SessionBridge(session: session)

        let live = manager.open(
            hostID: hostID,
            title: "Claude Code · Prod Box",
            session: session,
            bridge: bridge,
            aiAgentContext: context
        )

        XCTAssertEqual(live.isTmuxBacked, true)
        XCTAssertEqual(manager.cacheRevision, 1)

        let resumable = manager.resumableAISession
        XCTAssertEqual(resumable?.hostID, hostID)
        XCTAssertEqual(resumable?.hostLabel, "Prod Box")
        XCTAssertEqual(resumable?.sessionName, "termapp-ai-claude-term-app")
        XCTAssertEqual(resumable?.agentSlug, "claude")
        XCTAssertEqual(resumable?.projectSlug, "term-app")
        XCTAssertEqual(resumable?.currentPath, "~/projects/term-app")
        XCTAssertEqual(resumable?.isTermAppManaged, true)
        XCTAssertEqual(resumable?.detectedCommand, "claude")
        XCTAssertEqual(resumable?.wasOpenInApp, true)

        // Simulate app termination / iOS eviction without calling SessionManager.close:
        // a brand new SessionManager instance still sees the resumable AI session.
        let restartedManager = SessionManager(cacheDefaults: defaults)
        XCTAssertTrue(restartedManager.sessions.isEmpty)
        XCTAssertEqual(restartedManager.resumableAISession?.sessionName, "termapp-ai-claude-term-app")
        XCTAssertEqual(restartedManager.resumableAISession?.wasOpenInApp, true)
    }

    func testSessionManagerSkipsNonTmuxAndPlainSessionsAndMarksCloseNotOpenInApp() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        let manager = SessionManager(cacheDefaults: defaults)

        // Plain terminal session without AI context does not populate AI session cache.
        let plainSession = StubSession()
        _ = manager.open(
            hostID: hostID,
            title: "Plain Box",
            session: plainSession,
            bridge: SessionBridge(session: plainSession)
        )
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [])
        XCTAssertNil(manager.resumableAISession)

        // Non-tmux AI session does not populate resumable AI session cache.
        let codex = AIAgentDescriptor(builtIn: .codex)
        let nonTmuxContext = AIAgentLaunchContext(
            agent: codex,
            sessionName: "termapp-ai-codex-app",
            workingDirectory: "~/app",
            hostID: hostID,
            isTmuxBacked: false
        )
        let nonTmuxSession = StubSession()
        _ = manager.open(
            hostID: hostID,
            title: "Direct Box",
            session: nonTmuxSession,
            bridge: SessionBridge(session: nonTmuxSession),
            aiAgentContext: nonTmuxContext,
            isTmuxBacked: false
        )
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [])
        XCTAssertNil(manager.resumableAISession)

        // Tmux-backed AI session with direct host title caches properly and clears wasOpenInApp on close().
        let agy = AIAgentDescriptor(builtIn: .agy)
        let tmuxContext = AIAgentLaunchContext(
            agent: agy,
            sessionName: "termapp-ai-agy-repo",
            workingDirectory: "~/repo",
            hostID: hostID,
            isTmuxBacked: true
        )
        let tmuxSession = StubSession()
        let live = manager.open(
            hostID: hostID,
            title: "Mac Studio",
            session: tmuxSession,
            bridge: SessionBridge(session: tmuxSession),
            aiAgentContext: tmuxContext
        )

        let revisionBeforeClose = manager.cacheRevision
        XCTAssertEqual(manager.resumableAISession?.hostLabel, "Mac Studio")
        XCTAssertEqual(manager.resumableAISession?.wasOpenInApp, true)

        manager.close(live.id)

        XCTAssertGreaterThan(manager.cacheRevision, revisionBeforeClose)
        XCTAssertNil(manager.resumableAISession)
        let cachedAfterClose = AISessionCacheStore.load(defaults: defaults)
        XCTAssertEqual(cachedAfterClose.count, 1)
        XCTAssertEqual(cachedAfterClose.first?.sessionName, "termapp-ai-agy-repo")
        XCTAssertEqual(cachedAfterClose.first?.wasOpenInApp, false)
    }

    func testActiveSessionPillResumableModeInitializesCleanly() {
        var resumed = false
        var dismissed = false
        let pill = ActiveSessionPill(
            agentName: "Claude Code",
            agentSymbol: "sparkles",
            agentTint: .orange,
            subtitle: "Prod Box · term-app",
            isDark: true,
            onResume: { resumed = true },
            onDismiss: { dismissed = true }
        )
        pill.onResume()
        if case .resumable(let agentName, _, _, let subtitle, let onDismiss) = pill.mode {
            XCTAssertEqual(agentName, "Claude Code")
            XCTAssertEqual(subtitle, "Prod Box · term-app")
            onDismiss()
        } else {
            XCTFail("Expected .resumable mode")
        }
        XCTAssertTrue(resumed)
        XCTAssertTrue(dismissed)
    }

    func testScanResultRequiresExitZeroAndCompletionSentinelPreservingCache() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        let target = AgentHostTarget(
            id: hostID,
            label: "Mac Studio",
            hostname: "studio.local",
            authMethod: "key"
        )
        let cached = CachedAISession(
            hostID: hostID,
            hostLabel: "Mac Studio",
            sessionName: "termapp-ai-claude-repo",
            agentSlug: "claude",
            projectSlug: "repo",
            currentPath: "~/repo",
            isTermAppManaged: true,
            detectedCommand: "claude",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500),
            wasOpenInApp: true
        )
        AISessionCacheStore.upsert(cached, defaults: defaults)

        // 1. Empty stdout with exitCode 0 (truncated/incomplete) must NOT become .ok(0) and must preserve cache.
        let emptyOutcome = AgentsDashboardView.evaluateScanResult(
            SSHExecResult(stdout: "", stderr: "", exitCode: 0),
            target: target,
            knownCommands: [:]
        )
        if case .unreachable = emptyOutcome.status {
            // expected
        } else {
            XCTFail("Expected .unreachable for output missing TERMAPP_PANES_BEGIN, got \(emptyOutcome.status)")
        }

        let afterEmpty = AgentsDashboardView.applyScanOutcomes([emptyOutcome], cacheDefaults: defaults)
        XCTAssertEqual(afterEmpty.count, 1)
        XCTAssertEqual(afterEmpty.first?.isCached, true)
        XCTAssertEqual(afterEmpty.first?.session.sessionName, "termapp-ai-claude-repo")
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [cached])

        // 2. Non-zero exitCode (e.g. non-POSIX shell syntax error) even with sentinel/missing marker must NOT wipe cache.
        let nonZeroOutcome = AgentsDashboardView.evaluateScanResult(
            SSHExecResult(stdout: "TERMAPP_TMUX_MISSING\n", stderr: "fish: Unknown command", exitCode: 127),
            target: target,
            knownCommands: [:]
        )
        XCTAssertEqual(nonZeroOutcome.status, .unreachable(reason: "fish: Unknown command"))
        let afterNonZero = AgentsDashboardView.applyScanOutcomes([nonZeroOutcome], cacheDefaults: defaults)
        XCTAssertEqual(afterNonZero.count, 1)
        XCTAssertEqual(afterNonZero.first?.isCached, true)
        XCTAssertEqual(AISessionCacheStore.load(defaults: defaults), [cached])

        // 3. Clean exitCode 0 + TERMAPP_PANES_BEGIN with 0 sessions IS a valid .ok(sessionCount: 0) and prunes cache.
        let cleanEmptyOutcome = AgentsDashboardView.evaluateScanResult(
            SSHExecResult(stdout: "\(TMuxSessionHelper.panesBeginMarker)\n", stderr: "", exitCode: 0),
            target: target,
            knownCommands: [:]
        )
        XCTAssertEqual(cleanEmptyOutcome.status, .ok(sessionCount: 0))
        let afterCleanEmpty = AgentsDashboardView.applyScanOutcomes([cleanEmptyOutcome], cacheDefaults: defaults)
        XCTAssertTrue(afterCleanEmpty.isEmpty)
        XCTAssertTrue(AISessionCacheStore.load(defaults: defaults).isEmpty)

        // 4. Clean exitCode 0 + TERMAPP_TMUX_MISSING returns .tmuxMissing and clears cache.
        AISessionCacheStore.upsert(cached, defaults: defaults)
        let missingOutcome = AgentsDashboardView.evaluateScanResult(
            SSHExecResult(stdout: "\(TMuxSessionHelper.tmuxMissingMarker)\n", stderr: "", exitCode: 0),
            target: target,
            knownCommands: [:]
        )
        XCTAssertEqual(missingOutcome.status, .tmuxMissing)
        let afterMissing = AgentsDashboardView.applyScanOutcomes([missingOutcome], cacheDefaults: defaults)
        XCTAssertTrue(afterMissing.isEmpty)
        XCTAssertTrue(AISessionCacheStore.load(defaults: defaults).isEmpty)
    }

    func testLaunchSheetParallelSessionResolutionAndIndependentTracking() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }

        let hostID = UUID()
        let otherHostID = UUID()
        let manager = SessionManager(cacheDefaults: defaults)
        let claude = AIAgentDescriptor(builtIn: .claude)

        // Cached session on same host and an identically named session on a different host.
        AISessionCacheStore.upsert(
            CachedAISession(
                hostID: otherHostID,
                hostLabel: "Other Host",
                sessionName: "termapp-ai-claude-term-app-2",
                agentSlug: "claude",
                projectSlug: "term-app",
                currentPath: "~/projects/term-app",
                wasOpenInApp: false
            ),
            defaults: defaults
        )

        let firstContext = AIAgentLaunchContext(
            agent: claude,
            sessionName: "termapp-ai-claude-term-app",
            workingDirectory: "~/projects/term-app",
            hostID: hostID
        )
        let firstStub = StubSession()
        _ = manager.open(
            hostID: hostID,
            title: "Claude Code · Prod Box",
            session: firstStub,
            bridge: SessionBridge(session: firstStub),
            aiAgentContext: firstContext
        )

        // Known names for hostID only include sessions on hostID, ignoring otherHostID.
        let known = LaunchAIAgentSheet.knownSessionNames(
            for: hostID,
            openSessions: manager.sessions,
            cacheDefaults: defaults
        )
        XCTAssertEqual(known, ["termapp-ai-claude-term-app"])

        // New Session mode automatically advances to -2 when base session exists.
        XCTAssertEqual(
            LaunchAIAgentSheet.resolveSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: known,
                customSuffix: nil,
                reattachExisting: false
            ),
            "termapp-ai-claude-term-app-2"
        )

        // Custom session label appends cleanly in New Session mode.
        XCTAssertEqual(
            LaunchAIAgentSheet.resolveSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: known,
                customSuffix: "bugfix",
                reattachExisting: false
            ),
            "termapp-ai-claude-term-app-bugfix"
        )

        // Reattach Existing always uses the deterministic base session name.
        XCTAssertEqual(
            LaunchAIAgentSheet.resolveSessionName(
                agentSlug: "claude",
                workingDirectory: "~/projects/term-app",
                existingNames: known,
                customSuffix: "bugfix",
                reattachExisting: true
            ),
            "termapp-ai-claude-term-app"
        )

        // Opening the second parallel session keeps both live and cached independently.
        let secondContext = AIAgentLaunchContext(
            agent: claude,
            sessionName: "termapp-ai-claude-term-app-2",
            workingDirectory: "~/projects/term-app",
            hostID: hostID
        )
        let secondStub = StubSession()
        _ = manager.open(
            hostID: hostID,
            title: "Claude Code · Prod Box",
            session: secondStub,
            bridge: SessionBridge(session: secondStub),
            aiAgentContext: secondContext
        )

        XCTAssertEqual(manager.sessions.count, 2)
        let cachedNames = Set(AISessionCacheStore.load(defaults: defaults).filter { $0.hostID == hostID }.map(\.sessionName))
        XCTAssertEqual(cachedNames, ["termapp-ai-claude-term-app", "termapp-ai-claude-term-app-2"])
    }
}

private final class StubSession: Session, @unchecked Sendable {
    let output: AsyncStream<Data> = AsyncStream { _ in }
    let state: AsyncStream<SessionState> = AsyncStream { _ in }

    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {}
}
