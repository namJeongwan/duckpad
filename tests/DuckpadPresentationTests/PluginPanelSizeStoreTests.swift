import DuckpadDomain
@testable import DuckpadPresentation
import Foundation
import Testing

@MainActor
struct PluginPanelSizeStoreTests {
    @Test func validNarrowPanelsPersistIndependentlyAndInvalidSizesAreIgnored() throws {
        let suite = "duckpad-native-width-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ExtensionCommandID(rawValue: "com.test.first")
        let second = ExtensionCommandID(rawValue: "com.test.second")
        let sizes = PluginPanelSizeStore(defaults: defaults)
        sizes.save(240, for: first); sizes.save(510, for: second)
        sizes.save(.nan, for: first); sizes.save(0, for: second)
        let reopened = PluginPanelSizeStore(defaults: defaults)
        #expect(reopened.width(for: first) == 240)
        #expect(reopened.width(for: second) == 510)
    }
}
