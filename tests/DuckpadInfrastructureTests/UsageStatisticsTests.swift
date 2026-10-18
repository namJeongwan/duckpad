import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

private actor UsageRecorder {
    var batches: [[UsageStatisticsEvent]] = []
    let result: UsageStatisticsDelivery
    init(_ result: UsageStatisticsDelivery = .sent) { self.result = result }
    func send(_ events: [UsageStatisticsEvent]) -> UsageStatisticsDelivery {
        batches.append(events)
        return result
    }
}

@MainActor
private func makeUsage(_ defaults: UserDefaults, recorder: UsageRecorder,
    clock: @escaping () -> Date = Date.init, languages: Set<String> = ["swift", "python"]
) -> UsageStatistics {
    UsageStatistics(defaults: defaults,
        system: .init(isDebug: true, osVersion: "26.0", appVersion: "0.12.0", appBuildNumber: "58"),
        languages: languages, sender: { await recorder.send($0) }, clock: clock)
}

@Test @MainActor func usageRequiresEnabledCollectorAndConfiguration() async {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = UsageRecorder()
    let usage = makeUsage(defaults, recorder: recorder)
    usage.recordEdit(language: "swift")
    usage.record(.feature(.find))
    usage.flush()
    await usage.waitForDelivery()
    #expect(usage.pendingCount == 0)
    #expect(await recorder.batches.isEmpty)
    #expect(defaults.object(forKey: "usage.hasObserved") == nil)
    let unconfigured = UsageStatistics(defaults: defaults,
        system: .init(isDebug: true, osVersion: "26", appVersion: "1", appBuildNumber: "1"),
        languages: [], sender: nil)
    unconfigured.setEnabled(true)
    #expect(!unconfigured.isEnabled)
    #expect(unconfigured.pendingCount == 0)
}

@Test @MainActor func usageCoalescesEditingAndExcludesPrivateDimensions() async throws {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = UsageRecorder()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let usage = makeUsage(defaults, recorder: recorder, clock: { now })
    usage.setEnabled(true, automaticFlush: false)
    for _ in 0..<10_000 { usage.recordEdit(language: "swift") }
    now.addTimeInterval(60)
    usage.recordEdit(language: "swift")
    usage.recordEdit(language: "/Users/secret/customer-document")
    usage.record(.init(.pluginInvoke, dimension: "private.customer.plugin", outcome: .failed))
    usage.record(.init(.feature, dimension: "secret search text"))
    usage.flush()
    await usage.waitForDelivery()
    let events = try #require(await recorder.batches.first)
    #expect(events.first { $0.eventName == "editor_active_minute" && $0.props.dimension == "swift" }?.props.count == 2)
    #expect(events.first { $0.eventName == "plugin_invoked" }?.props.dimension == "other")
    #expect(!usage.transmissionLog.contains("secret"))
    #expect(!usage.transmissionLog.contains("customer"))
    #expect(events.filter { $0.eventName == "app_active_day" }.count == 1)
    usage.setEnabled(false)
    #expect(usage.transmissionLog.isEmpty)
    #expect(usage.pendingCount == 0)
}

@Test @MainActor func usageBoundsOfflineQueueAndRetries() async {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = UsageRecorder(.retry)
    let usage = makeUsage(defaults, recorder: recorder)
    usage.setEnabled(true, automaticFlush: false)
    usage.record(.feature(.find))
    for _ in 0..<5 {
        usage.flush()
        await usage.waitForDelivery()
    }
    #expect(await recorder.batches.count == 3)
    #expect(usage.pendingCount == 0)
    let languages = Set((0..<200).map { "language_\($0)" })
    let bounded = makeUsage(defaults, recorder: recorder, languages: languages)
    bounded.setEnabled(true, automaticFlush: false)
    for language in languages { bounded.recordEdit(language: language) }
    #expect(bounded.pendingCount == UsageStatistics.maximumCounters)
}

@Test @MainActor func usageOptOutDiscardsInFlightRetryAndPendingData() async {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = UsageStatistics(defaults: defaults,
        system: .init(isDebug: true, osVersion: "26", appVersion: "1", appBuildNumber: "1"),
        languages: ["swift"], sender: { _ in
            try? await Task.sleep(for: .seconds(60))
            return .retry
        })
    usage.setEnabled(true, automaticFlush: false)
    usage.flush()
    await Task.yield()
    usage.recordEdit(language: "swift")
    usage.setEnabled(false)
    await Task.yield()
    #expect(!usage.isEnabled)
    #expect(usage.pendingCount == 0)
    #expect(usage.transmissionLog.isEmpty)
}

@Test func usageSettingsDefaultOnAndPreserveExplicitOptOut() throws {
    let legacy = Data(#"{"schemaVersion":1,"appearanceMode":"system","defaultWordWrapEnabled":true,"defaultWrapMarkerVisible":false}"#.utf8)
    #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).shareUsageStatistics)
    #expect(AppSettings.defaults.shareUsageStatistics)
    var settings = AppSettings.defaults
    settings.shareUsageStatistics = false
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(!restored.shareUsageStatistics)
}

@Test func usageTransportRequiresPublicHTTPSConfiguration() {
    let key = "A-SH-1234567890"
    #expect(UsageStatisticsTransport(host: "https://stats.example.com", appKey: key) != nil)
    for host in ["http://stats.example.com", "https://user:password@stats.example.com", "https://stats.example.com/?token=secret", "https://stats.example.com/path"] {
        #expect(UsageStatisticsTransport(host: host, appKey: key) == nil)
    }
    #expect(UsageStatisticsTransport(host: "https://stats.example.com", appKey: "admin-token") == nil)
}

@Test @MainActor func usageUnsentFirstSessionDoesNotSuppressLifecycleOnRelaunch() async throws {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = UsageRecorder()
    let first = makeUsage(defaults, recorder: recorder)
    first.setEnabled(true, automaticFlush: false)
    first.setEnabled(false) // Quit before the first five-minute flush.
    #expect(defaults.object(forKey: "usage.hasObserved") == nil)
    #expect(defaults.object(forKey: "usage.version") == nil)
    #expect(defaults.object(forKey: "usage.activeDay") == nil)
    let next = makeUsage(defaults, recorder: recorder)
    next.setEnabled(true, automaticFlush: false)
    next.flush()
    await next.waitForDelivery()
    let batch = try #require(await recorder.batches.last)
    #expect(batch.contains { $0.eventName == "app_first_observed" })
    #expect(batch.contains { $0.eventName == "app_active_day" })
    #expect(defaults.bool(forKey: "usage.hasObserved"))
    #expect(defaults.string(forKey: "usage.version") == "0.12.0")
    next.setEnabled(false)
    let acknowledged = makeUsage(defaults, recorder: recorder)
    acknowledged.setEnabled(true, automaticFlush: false)
    #expect(acknowledged.pendingCount == 0)
}

@Test @MainActor func usageRejectedVersionChangeRemainsEligibleOnRelaunch() async throws {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "usage.hasObserved")
    defaults.set("0.11.0", forKey: "usage.version")
    let failed = makeUsage(defaults, recorder: UsageRecorder(.discarded))
    failed.setEnabled(true, automaticFlush: false)
    failed.flush()
    await failed.waitForDelivery()
    failed.setEnabled(false)
    #expect(defaults.string(forKey: "usage.version") == "0.11.0")
    #expect(defaults.object(forKey: "usage.activeDay") == nil)
    let recorder = UsageRecorder()
    let next = makeUsage(defaults, recorder: recorder)
    next.setEnabled(true, automaticFlush: false)
    next.flush()
    await next.waitForDelivery()
    let batch = try #require(await recorder.batches.last)
    #expect(batch.first { $0.eventName == "app_version_changed" }?.props.dimension == "0.11.0")
    #expect(batch.contains { $0.eventName == "app_active_day" })
    #expect(defaults.string(forKey: "usage.version") == "0.12.0")
}

@Test @MainActor func usageDailyActivityKeepsSeparateDatesAcrossMidnight() async throws {
    let suite = "usage-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = UsageRecorder()
    var now = Date(timeIntervalSince1970: 20_000 * 86400 + 86340)
    let usage = makeUsage(defaults, recorder: recorder, clock: { now })
    usage.setEnabled(true, automaticFlush: false)
    now.addTimeInterval(120)
    usage.recordActivity()
    usage.recordActivity()
    usage.flush()
    await usage.waitForDelivery()
    let batch = try #require(await recorder.batches.last)
    let days = batch.filter { $0.eventName == "app_active_day" }
    #expect(days.count == 2)
    #expect(days.allSatisfy { $0.props.count == 1 })
    #expect(Set(days.map { Int($0.timestamp.timeIntervalSince1970 / 86400) }) == [20_000, 20_001])
    #expect(defaults.integer(forKey: "usage.activeDay") == 20_001)
}
