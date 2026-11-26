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
}

private final class StubSession: Session, @unchecked Sendable {
    let output: AsyncStream<Data> = AsyncStream { _ in }
    let state: AsyncStream<SessionState> = AsyncStream { _ in }

    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {}
}
