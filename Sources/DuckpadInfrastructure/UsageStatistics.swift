import Foundation
import DuckpadDomain

/// Bounded counters on the UI thread; serialization and HTTP run off that thread.
/// There is no task, disk write, or network request for each keystroke.
@MainActor
public final class UsageStatistics {
    public typealias Sender = @Sendable ([UsageStatisticsEvent]) async -> UsageStatisticsDelivery
    private struct Key: Hashable {
        let kind: String
        let dimension: String
        let outcome: String
        let duration: String
        let day: Int
    }
    private struct Pending {
        var event: UsageStatisticsEvent
        var attempts = 0
    }
    public static let maximumCounters = 128
    private let sender: Sender?
    private let defaults: UserDefaults
    private let system: UsageStatisticsEvent.SystemProperties
    private let languages: Set<String>
    private let clock: () -> Date
    private let sessionID = UUID().uuidString
    private var counters: [Key: Pending] = [:]
    private var lastActiveDay: Int?
    private var lastEditMinutes: [String: Int] = [:]
    private var timer: Task<Void, Never>?
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private var recentBatches: [String] = []
    public private(set) var isEnabled = false
    public var isConfigured: Bool { sender != nil }
    public var pendingCount: Int { counters.count }
    public var transmissionLog: String { recentBatches.joined(separator: "\n\n") }

    public init(defaults: UserDefaults, system: UsageStatisticsEvent.SystemProperties,
        languages: Set<String>, sender: Sender?, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.system = system
        self.languages = languages
        self.sender = sender
        self.clock = clock
    }

    deinit { timer?.cancel(); delivery?.cancel() }

    public func setEnabled(_ enabled: Bool, automaticFlush: Bool = true) {
        let enabled = enabled && isConfigured
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        generation = UUID()
        timer?.cancel(); timer = nil
        delivery?.cancel(); delivery = nil
        counters.removeAll(); lastEditMinutes.removeAll(); recentBatches.removeAll()
        lastActiveDay = defaults.object(forKey: "usage.activeDay") as? Int
        guard enabled else { return }
        if !defaults.bool(forKey: "usage.hasObserved") {
            record(.init(.firstObserved))
        }
        let previous = defaults.string(forKey: "usage.version")
        if let previous, previous != system.appVersion {
            record(.init(.versionChanged, dimension: previous))
        }
        recordActivity()
        if automaticFlush {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    guard let self else { return }
                    self.flush()
                }
            }
        }
    }

    public func recordActivity() {
        guard isEnabled else { return }
        let day = Int(clock().timeIntervalSince1970 / 86400)
        guard lastActiveDay != day else { return }
        lastActiveDay = day
        record(.init(.activeDay))
    }

    public func recordEdit(language: String) {
        guard isEnabled else { return }
        let language = languages.contains(language) ? language : "other"
        let minute = Int(clock().timeIntervalSince1970 / 60)
        guard lastEditMinutes[language] != minute else { return }
        lastEditMinutes[language] = minute
        recordActivity()
        record(.init(.editMinute, dimension: language))
    }

    public func record(_ metric: UsageMetric) {
        guard isEnabled else { return }
        let dimension: String
        switch metric.kind {
        case .editMinute:
            dimension = languages.contains(metric.dimension) ? metric.dimension : "other"
        case .feature:
            guard UsageMetric.Feature(rawValue: metric.dimension) != nil else { return }
            dimension = metric.dimension
        case .pluginInstall, .pluginUpdate, .pluginRemove, .pluginInvoke, .pluginPanel:
            // Only public, shipped/catalogued IDs. Private extensions collapse to "other".
            let known = ["com.duckpad.text-tools", "com.duckpad.clipboard-history", "com.duckpad.plantuml"]
            dimension = known.contains(metric.dimension) ? metric.dimension : "other"
        case .versionChanged:
            dimension = metric.dimension.range(of: #"^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$"#, options: .regularExpression) != nil ? metric.dimension : "other"
        case .firstObserved, .activeDay, .format: dimension = ""
        }
        let duration = Self.durationBucket(metric.duration)
        let timestamp = clock()
        let key = Key(kind: metric.kind.rawValue, dimension: dimension, outcome: metric.outcome.rawValue, duration: duration, day: Int(timestamp.timeIntervalSince1970 / 86400))
        if counters[key] != nil {
            counters[key]!.event.props.count = min(1_000_000, counters[key]!.event.props.count + 1)
        } else if counters.count < Self.maximumCounters {
            counters[key] = Pending(event: .init(timestamp: timestamp, sessionId: sessionID,
                eventName: key.kind, systemProps: system,
                props: .init(dimension: dimension, outcome: key.outcome, durationBucket: duration, count: 1)))
        }
    }

    public func flush() {
        guard isEnabled, delivery == nil, let sender else { return }
        // The server accepts events younger than one day. Never grow an offline backlog.
        counters = counters.filter { clock().timeIntervalSince($0.value.event.timestamp) < 23 * 3600 }
        let batch = Array(counters.sorted { $0.value.event.timestamp < $1.value.event.timestamp }.prefix(25))
        guard !batch.isEmpty else { return }
        for entry in batch { counters.removeValue(forKey: entry.key) }
        let generation = generation
        delivery = Task { [weak self] in
            let events = batch.map { $0.value.event }
            let result = await sender(events)
            let log = await Task.detached(priority: .utility) { Self.renderBatch(events, result: result) }.value
            guard let self, self.isEnabled, self.generation == generation, !Task.isCancelled else { return }
            self.delivery = nil
            if let log {
                self.recentBatches.append(log)
                self.recentBatches = Array(self.recentBatches.suffix(5))
            }
            if case .sent = result { self.acknowledge(events) }
            if case .retry = result {
                for (key, var pending) in batch where pending.attempts < 2 {
                    pending.attempts += 1
                    if var newer = self.counters[key] {
                        // Do not reset the retry budget when new activity arrives.
                        newer.event.props.count = min(1_000_000, newer.event.props.count + pending.event.props.count)
                        newer.attempts = max(newer.attempts, pending.attempts)
                        self.counters[key] = newer
                    } else if self.counters.count < Self.maximumCounters {
                        self.counters[key] = pending
                    }
                }
            }
        }
    }

    // Persist lifecycle markers only after delivery; short runs and failures must
    // remain eligible on the next launch. Pending activity is suppressed in memory.
    private func acknowledge(_ events: [UsageStatisticsEvent]) {
        for event in events {
            switch event.eventName {
            case UsageMetric.Kind.firstObserved.rawValue:
                defaults.set(true, forKey: "usage.hasObserved")
                defaults.set(system.appVersion, forKey: "usage.version")
            case UsageMetric.Kind.versionChanged.rawValue:
                defaults.set(system.appVersion, forKey: "usage.version")
            case UsageMetric.Kind.activeDay.rawValue:
                let day = Int(event.timestamp.timeIntervalSince1970 / 86400)
                let previous = defaults.object(forKey: "usage.activeDay") as? Int
                defaults.set(max(previous ?? day, day), forKey: "usage.activeDay")
            default: break
            }
        }
    }

    public func waitForDelivery() async { await delivery?.value }

    private nonisolated static func renderBatch(_ events: [UsageStatisticsEvent], result: UsageStatisticsDelivery) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events), let json = String(data: data, encoding: .utf8) else { return nil }
        let status: String
        switch result { case .sent: status = "sent"; case .retry: status = "retry"; case .discarded: status = "discarded" }
        return status + "\n" + json
    }

    private static func durationBucket(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "none" }
        if duration < 0.1 { return "under_100ms" }
        if duration < 1 { return "under_1s" }
        if duration < 5 { return "under_5s" }
        return "5s_or_more"
    }
}
