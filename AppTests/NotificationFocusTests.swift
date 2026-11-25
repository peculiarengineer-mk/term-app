import Foundation
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

    func testAppLockManagerLockAndDisableResetsAuthenticationState() {
        let suiteName = "com.peculiarengineer.termapp.tests.applock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
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
}
