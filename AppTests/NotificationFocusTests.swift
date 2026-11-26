import Foundation
import os
import SSHKit
import Store
import UserNotifications
import XCTest
@testable import TermApp

@MainActor
final class NotificationFocusTests: XCTestCase {
    func testConfigureDelegateAssignsNonisolatedProxy() {
        let manager = AgentNotificationManager.shared
        manager.configureDelegate()

        let delegate = UNUserNotificationCenter.current().delegate
        XCTAssertNotNil(delegate)
        XCTAssertTrue((delegate as AnyObject) !== (manager as AnyObject))
    }

    func testHandleNotificationTapStoresPendingFocusAndPostsNotification() {
        let center = NotificationCenter()
        let manager = AgentNotificationManager(notificationCenter: center)

        let sessionID = UUID()
        let expectation = XCTNSNotificationExpectation(
            name: .termFocusAgentSession,
            object: nil,
            notificationCenter: center
        )
        expectation.handler = { note in
            (note.userInfo?[AgentNotificationManager.sessionIDKey] as? UUID) == sessionID
        }

        manager.handleNotificationTap(sessionID: sessionID)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(manager.pendingFocusSessionID, sessionID)
        XCTAssertEqual(manager.consumePendingFocusSessionID(), sessionID)
        XCTAssertNil(manager.pendingFocusSessionID)
        XCTAssertNil(manager.consumePendingFocusSessionID())
    }

    func testLiveSessionTabsIgnoresMissingSessionAndConsumesPendingFocus() async {
        let manager = AgentNotificationManager.shared
        _ = manager.consumePendingFocusSessionID()
        defer { _ = manager.consumePendingFocusSessionID() }

        manager.handleNotificationTap(sessionID: UUID())
        await Task.yield()

        XCTAssertNil(manager.pendingFocusSessionID)
    }

    func testAppLockManagerLockAndDisableResetsAuthenticationState() throws {
        let suiteName = "com.peculiarengineer.termapp.tests.applock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppLockManager.defaultsKey)
        let appLock = AppLockManager(defaults: defaults)
        XCTAssertTrue(appLock.appLockEnabled)
        XCTAssertTrue(appLock.isLocked)
        XCTAssertFalse(appLock.isAuthenticating)

        appLock.lockIfEnabled()
        XCTAssertTrue(appLock.isLocked)
        XCTAssertFalse(appLock.isAuthenticating)
        XCTAssertNil(appLock.authError)

        appLock.setEnabled(false)
        XCTAssertFalse(appLock.appLockEnabled)
        XCTAssertFalse(appLock.isLocked)
        XCTAssertFalse(appLock.isAuthenticating)
        XCTAssertNil(appLock.authError)
    }

    // MARK: - Anti-Spam Notification Gating

    func testCompletionDebounceDefaultIsTwelveSeconds() {
        XCTAssertEqual(LiveSession.completionDebounceDuration, .seconds(12))
    }

    func testInitialAttachAndLaunchCommandDoNotFireFinished() async throws {
        let harness = try makeTrackedHarness(pendingLaunchCommand: "tmux new -A -s termapp-ai-claude-repo 'claude'")
        defer { harness.cleanup() }

        harness.live.dispatchPendingLaunchCommandIfReady()

        let commandSent = await waitFor {
            harness.session.writtenPayloads.count == 1
        }
        XCTAssertTrue(commandSent)

        // Initial tmux screen replay and startup banner must not arm a turn.
        harness.session.emitOutput("Claude Code v1.0\r\nWelcome to your workspace.\r\nReady for instructions.\r\n> ")
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)
    }

    func testProgrammaticTmuxAttachOnReconnectDoesNotArmFinished() async throws {
        let harness = try makeTrackedHarness()
        defer { harness.cleanup() }

        harness.live.sendProgrammaticTmuxAttach("tmux attach -t termapp-ai-claude-repo")
        try await Task.sleep(for: .milliseconds(10))

        harness.session.emitOutput("Reattached to tmux session with plenty of existing terminal history output.\r\n> ")
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)

        // A nil tmux command must not consume the user's subsequent real Enter.
        harness.live.sendProgrammaticTmuxAttach(nil)
        try await sendUserInput("explain architecture\r", via: harness.bridge)
        harness.session.emitOutput("Here is a comprehensive overview of the codebase modules and state flow.")

        let notified = await waitFor { harness.dispatched.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(harness.dispatched.first?.state, .completed)
    }

    func testTypingWithoutEnterAndPasteWithoutSubmitDoNotArmFinished() async throws {
        let harness = try makeTrackedHarness()
        defer { harness.cleanup() }

        // Typing characters without pressing Enter.
        try await sendUserInput("explain this repository", via: harness.bridge)
        harness.session.emitOutput("Autocomplete suggestions and status footer text exceeding twenty four chars.")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)

        // Bracketed paste containing newlines without Submit.
        let pasteOnly = TMuxSessionHelper.bracketedPastePayload(
            for: "line one\nline two\nline three",
            submit: false
        )
        try await sendUserInput(Array(pasteOnly), via: harness.bridge)
        harness.session.emitOutput("Pasted preview text rendered in terminal buffer with lots of characters.")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)

        // Ctrl-C must not arm a turn.
        try await sendUserInput("\u{03}", via: harness.bridge)
        harness.session.emitOutput("^C\r\nSession interrupted and returned to prompt successfully.")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)

        // Bracketed paste WITH Submit DOES arm a turn.
        let pasteAndSubmit = TMuxSessionHelper.bracketedPastePayload(
            for: "line one\nline two",
            submit: true
        )
        try await sendUserInput(Array(pasteAndSubmit), via: harness.bridge)
        harness.session.emitOutput("Processed both pasted lines and finished running checks successfully.")

        let notified = await waitFor { harness.dispatched.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(harness.dispatched.first?.title, "Claude Code Finished")
    }

    func testSpinnerBoxDrawingAnsiAndSingleCharEchoDoNotTriggerFinished() async throws {
        let harness = try makeTrackedHarness()
        defer { harness.cleanup() }

        try await sendUserInput("check status\r", via: harness.bridge)
        harness.session.emitOutput("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        harness.session.emitOutput("◐◓◑◒✶✸✹✺✻✽✳✢·•…")
        harness.session.emitOutput("╭──╮│╰──╯▀▄█")
        harness.session.emitOutput("\u{1B}[?25h\u{1B}[2K\u{1B}]0;working\u{07}")
        harness.session.emitOutput("a")
        try await Task.sleep(for: .milliseconds(40))
        harness.session.emitOutput("7")

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)
    }

    func testShortEchoedOutputUnderThresholdDoesNotFireFinished() async throws {
        let harness = try makeTrackedHarness()
        defer { harness.cleanup() }

        try await sendUserInput("fix bug\r", via: harness.bridge)
        harness.session.emitOutput("fix bug\r\n")
        try await Task.sleep(for: .milliseconds(30))
        harness.session.emitOutput("ok\r\n")

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(harness.dispatched.isEmpty)
    }

    func testSubmittedTurnFiresOnceAndSecondEnterArmsFreshTurn() async throws {
        let harness = try makeTrackedHarness()
        defer { harness.cleanup() }

        try await sendUserInput("run unit tests\r", via: harness.bridge)
        harness.session.emitOutput("Running StoreTests ")
        try await Task.sleep(for: .milliseconds(25))
        harness.session.emitOutput("and all 42 tests passed!")

        let firstNotified = await waitFor { harness.dispatched.count == 1 }
        XCTAssertTrue(firstNotified)
        XCTAssertEqual(harness.dispatched[0].title, "Claude Code Finished")
        XCTAssertEqual(harness.dispatched[0].state, .completed)
        XCTAssertEqual(harness.live.agentActivityState, .completed)

        // Trailing output without a new Enter must NOT re-arm or fire another Finished notification.
        harness.session.emitOutput("Trailing status update line with more than twenty four meaningful characters.")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(harness.dispatched.count, 1)
        XCTAssertEqual(harness.live.agentActivityState, .completed)

        // Empty Enter from .completed resets to .idle and does not get stuck in .running.
        try await sendUserInput("\r", via: harness.bridge)
        XCTAssertEqual(harness.live.agentActivityState, .idle)
        harness.session.emitOutput("\r\n> ")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(harness.live.agentActivityState, .idle)
        XCTAssertEqual(harness.dispatched.count, 1)

        // Second real prompt arms a fresh turn and fires once when done.
        try await sendUserInput("summarize changes\r", via: harness.bridge)
        harness.session.emitOutput("Summarized all notification anti-spam changes across Store and TermApp.")

        let secondNotified = await waitFor { harness.dispatched.count == 2 }
        XCTAssertTrue(secondNotified)
        XCTAssertEqual(harness.dispatched[1].title, "Claude Code Finished")
        XCTAssertEqual(harness.dispatched[1].state, .completed)
    }

    func testApprovalPromptDeduplicationAndCooldown() async throws {
        let harness = try makeTrackedHarness(approvalCooldownDuration: .seconds(15))
        defer { harness.cleanup() }

        // 1. First approval prompt notifies immediately.
        harness.session.emitOutput("Run swift test? [y/N]")
        let firstApproval = await waitFor { harness.dispatched.count == 1 }
        XCTAssertTrue(firstApproval)
        XCTAssertEqual(
            harness.dispatched[0].state,
            .waitingForApproval(prompt: "Run swift test? [y/N]")
        )

        // 2. Screen redraw of the same prompt does NOT re-notify.
        harness.clock.advance(by: 2)
        harness.session.emitOutput("\u{1B}[2JRun swift test? [y/N]")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(harness.dispatched.count, 1)

        // 3. Rapidly changed prompt within 15s cooldown updates UI state but does NOT notify.
        harness.clock.advance(by: 3)
        harness.session.emitOutput("\r\nConfirm?")
        let stateUpdated = await waitFor {
            harness.live.agentActivityState == .waitingForApproval(prompt: "Confirm?")
        }
        XCTAssertTrue(stateUpdated)
        XCTAssertEqual(harness.dispatched.count, 1)

        // 4. Past 15s cooldown, the previously-notified prompt STILL deduplicates...
        harness.clock.advance(by: 16)
        harness.session.emitOutput("\r\nRun swift test? [y/N]")
        let backToOldPrompt = await waitFor {
            harness.live.agentActivityState == .waitingForApproval(prompt: "Run swift test? [y/N]")
        }
        XCTAssertTrue(backToOldPrompt)
        XCTAssertEqual(harness.dispatched.count, 1)

        // 5. ...while a genuinely new approval prompt past the 15s cooldown DOES notify.
        harness.session.emitOutput("\r\nApply patch to 3 files? [y/N]")
        let secondApproval = await waitFor { harness.dispatched.count == 2 }
        XCTAssertTrue(secondApproval)
        XCTAssertEqual(
            harness.dispatched[1].state,
            .waitingForApproval(prompt: "Apply patch to 3 files? [y/N]")
        )
    }

    func testDisablingAIAgentControlsResetsTurnState() async throws {
        let harness = try makeTrackedHarness(includeAIContext: false)
        defer { harness.cleanup() }

        harness.live.showAIAgentControls = true
        try await sendUserInput("partial prompt\r", via: harness.bridge)
        harness.session.emitOutput("short")
        try await Task.sleep(for: .milliseconds(40))

        harness.live.showAIAgentControls = false
        XCTAssertEqual(harness.live.agentActivityState, .idle)

        harness.live.showAIAgentControls = true
        harness.session.emitOutput("Output arriving without a new user Enter must not trigger completion.")
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(harness.dispatched.isEmpty)
        XCTAssertEqual(harness.live.agentActivityState, .idle)
    }

    // MARK: - Helpers

    @MainActor
    private final class NotificationRecorder {
        var items: [AgentNotificationManager.DispatchedNotification] = []
    }

    private struct TrackedHarness {
        let live: LiveSession
        let session: StubActivitySession
        let bridge: SessionBridge
        let clock: TestClock
        let recorder: NotificationRecorder
        let cleanup: () -> Void

        @MainActor
        var dispatched: [AgentNotificationManager.DispatchedNotification] {
            recorder.items
        }
    }

    private func makeTrackedHarness(
        includeAIContext: Bool = true,
        pendingLaunchCommand: String? = nil,
        approvalCooldownDuration: Duration = .seconds(15)
    ) throws -> TrackedHarness {
        let suiteName = "com.peculiarengineer.termapp.tests.notifications.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let clock = TestClock(initial: Date(timeIntervalSince1970: 1_750_000_000))
        let recorder = NotificationRecorder()
        let manager = AgentNotificationManager(
            notificationCenter: NotificationCenter(),
            defaults: defaults,
            deliveryHandler: { note in
                recorder.items.append(note)
            }
        )

        let hostID = UUID()
        let session = StubActivitySession()
        let bridge = SessionBridge(session: session)
        let context: AIAgentLaunchContext? = includeAIContext
            ? AIAgentLaunchContext(
                agent: AIAgentDescriptor(builtIn: .claude),
                sessionName: "termapp-ai-claude-repo",
                workingDirectory: "~/repo",
                hostID: hostID
            )
            : nil

        let live = LiveSession(
            hostID: hostID,
            title: includeAIContext ? "Claude Code · Dev Box" : "Dev Box",
            session: session,
            bridge: bridge,
            aiAgentContext: context,
            pendingLaunchCommand: pendingLaunchCommand,
            completionDebounceDuration: .milliseconds(80),
            outputCoalesceInterval: .milliseconds(15),
            approvalCooldownDuration: approvalCooldownDuration,
            nowProvider: { clock.now },
            notificationManager: manager
        )

        return TrackedHarness(
            live: live,
            session: session,
            bridge: bridge,
            clock: clock,
            recorder: recorder,
            cleanup: {
                live.cleanupActivityTracking()
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    private func sendUserInput(_ text: String, via bridge: SessionBridge) async throws {
        try await sendUserInput(Array(text.utf8), via: bridge)
    }

    private func sendUserInput(_ bytes: [UInt8], via bridge: SessionBridge) async throws {
        bridge.send(bytes)
        try await Task.sleep(for: .milliseconds(10))
    }

    private func waitFor(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }
}

private final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(initial: Date) {
        self.current = OSAllocatedUnfairLock(initialState: initial)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private final class StubActivitySession: Session, Sendable {
    let output: AsyncStream<Data>
    let state: AsyncStream<SessionState>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let writtenStorage = OSAllocatedUnfairLock(initialState: [Data]())

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream<Data> { continuation = $0 }
        self.outputContinuation = continuation
        self.state = AsyncStream<SessionState> { _ in }
    }

    var writtenPayloads: [Data] {
        writtenStorage.withLock { $0 }
    }

    func emitOutput(_ text: String) {
        outputContinuation.yield(Data(text.utf8))
    }

    func connect(verifyHostKey: @Sendable (HostKey) async -> HostKeyDecision) async throws {}

    func write(_ data: Data) async throws {
        writtenStorage.withLock { $0.append(data) }
    }

    func resize(cols: Int, rows: Int) async throws {}

    func close() async {
        outputContinuation.finish()
    }
}
