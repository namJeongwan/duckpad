import DuckpadDomain
import Foundation

public enum AppSettingsStoreError: Error, Equatable, Sendable {
    case corrupt(String)
    case unsupportedSchema(Int)
    case readFailed(String)
    case writeFailed(String)
    case writeUncertain(String)
}

public protocol AppSettingsStore: Sendable {
    func load() async throws(AppSettingsStoreError) -> AppSettings?
    func save(_ settings: AppSettings) async throws(AppSettingsStoreError)
}

public enum AppSettingsState: Equatable, Sendable {
    case ready(AppSettings)
    case degraded(settings: AppSettings, failure: AppSettingsStoreError)

    public var settings: AppSettings {
        switch self {
        case .ready(let settings), .degraded(let settings, _): settings
        }
    }
}

public enum AppSettingsUpdateOutcome: Equatable, Sendable {
    case saved(AppSettings)
    case savedWithWarning(settings: AppSettings, failure: AppSettingsStoreError)
    case failed(AppSettingsStoreError)
}

@MainActor
public final class AppSettingsUseCase {
    private let store: any AppSettingsStore
    public private(set) var state: AppSettingsState = .ready(.defaults)
    public var onChange: ((AppSettingsState) -> Void)?

    public init(store: any AppSettingsStore) {
        self.store = store
    }

    @discardableResult
    public func start() async -> AppSettingsState {
        do {
            let settings = try await store.load() ?? .defaults
            guard settings.schemaVersion == AppSettings.currentSchemaVersion else {
                let failure = AppSettingsStoreError.unsupportedSchema(settings.schemaVersion)
                state = .degraded(settings: .defaults, failure: failure)
                onChange?(state)
                return state
            }
            state = .ready(settings)
        } catch let failure {
            state = .degraded(settings: .defaults, failure: failure)
        }
        onChange?(state)
        return state
    }

    @discardableResult
    public func update(_ settings: AppSettings) async -> AppSettingsUpdateOutcome {
        let normalized = AppSettings(
            appearanceMode: settings.appearanceMode,
            defaultWordWrapEnabled: settings.defaultWordWrapEnabled,
            defaultWrapMarkerVisible: settings.defaultWrapMarkerVisible
        )
        do {
            try await store.save(normalized)
            state = .ready(normalized)
            onChange?(state)
            return .saved(normalized)
        } catch let failure {
            if case .writeUncertain = failure {
                state = .degraded(settings: normalized, failure: failure)
                onChange?(state)
                return .savedWithWarning(settings: normalized, failure: failure)
            }
            return .failed(failure)
        }
    }
}
