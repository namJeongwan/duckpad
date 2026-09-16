import DuckpadApplication
import DuckpadInfrastructure
import Foundation

/// Exercise real bookmark behavior without changing the user's preferences.
@MainActor final class TestMarkdownImageAccess: MarkdownImageAccess {
    private let suite = "duckpad-image-access-test-" + UUID().uuidString
    private let access: LocalMarkdownImageAccess

    init() {
        access = LocalMarkdownImageAccess(defaults: UserDefaults(suiteName: suite)!)
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func remember(_ urls: [URL]) { access.remember(urls) }
    func acquire() -> [URL] { access.acquire() }
    func release(_ urls: [URL]) { access.release(urls) }
}
