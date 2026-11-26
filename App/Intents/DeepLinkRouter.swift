import Foundation
import Observation
import Store

/// Coordinates `termapp://` deep links from Widgets, Dynamic Island Live Activities, and App Intents.
@MainActor @Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private(set) var pendingLink: TermAppDeepLink?

    init() {}

    /// Queues a validated deep link to be executed once the main workspace is mounted and unlocked.
    func enqueue(_ link: TermAppDeepLink) {
        pendingLink = link
    }

    /// Parses `url` as a `TermAppDeepLink` and enqueues it if valid.
    @discardableResult
    func enqueue(url: URL) -> Bool {
        guard let link = TermAppDeepLink.parse(url) else { return false }
        enqueue(link)
        return true
    }

    /// Returns and clears the currently queued deep link, if any.
    func consumePendingLink() -> TermAppDeepLink? {
        defer { pendingLink = nil }
        return pendingLink
    }
}
