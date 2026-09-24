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
    private var updating = false
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []
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
        await acquireUpdate()
        defer { releaseUpdate() }
        // An already-open preferences window must not overwrite newer snippets.
        var proposed = settings
        proposed.snippets = state.settings.snippets
        return await persist(proposed)
    }

    public func updateSnippets(_ snippets: [TextSnippet], expected: [TextSnippet]) async -> AppSettingsUpdateOutcome {
        await acquireUpdate()
        defer { releaseUpdate() }
        guard state.settings.snippets == expected else { return .failed(.writeFailed("snippet list changed")) }
        guard snippets.count <= 200, Set(snippets.map(\.id)).count == snippets.count,
              snippets.allSatisfy({ !$0.name.isEmpty && !$0.body.isEmpty && $0.name.utf8.count <= 256 && $0.body.utf8.count <= 65_536 }),
              let data = try? JSONEncoder().encode(snippets), data.count <= 768 * 1024 else {
            return .failed(.writeFailed("snippet storage limit exceeded"))
        }
        var proposed = state.settings
        proposed.snippets = snippets
        return await persist(proposed)
    }

    private func acquireUpdate() async {
        if !updating { updating = true; return }
        await withCheckedContinuation { updateWaiters.append($0) }
    }

    private func releaseUpdate() {
        if updateWaiters.isEmpty { updating = false }
        else { updateWaiters.removeFirst().resume() }
    }

    private func persist(_ settings: AppSettings) async -> AppSettingsUpdateOutcome {
        var normalized = settings
        normalized.schemaVersion = AppSettings.currentSchemaVersion
        normalized.editorFontSize = settings.editorFontSize.isFinite ? (min(max(settings.editorFontSize, 6), 72) * 100).rounded() / 100 : 13
        if settings.editorFontName.isEmpty || settings.editorFontName.utf8.count > 256 { normalized.editorFontName = "Menlo" }
        normalized.editorLeftPadding = min(max(settings.editorLeftPadding, 0), 32)
        normalized.editorRightPadding = min(max(settings.editorRightPadding, 0), 32)
        normalized.editorLineSpacing = min(max(settings.editorLineSpacing, 0), 20)
        normalized.caretWidth = min(max(settings.caretWidth, 1), 3)
        normalized.caretBlinkPeriod = min(max(settings.caretBlinkPeriod, 0), 2000)
        normalized.wrapIndentMode = min(max(settings.wrapIndentMode, 0), 2)
        normalized.indentationWidth = min(max(settings.indentationWidth, 1), 16)
        normalized.edgeColumn = min(max(settings.edgeColumn, 1), 500)
        normalized.recentFileLimit = min(max(settings.recentFileLimit, 0), 50)
        normalized.recentFilePathMode = min(max(settings.recentFilePathMode, 0), 2)
        normalized.findSelectionMaximumCharacters = min(max(settings.findSelectionMaximumCharacters, 0), 16383)
        normalized.formatting.tabWidth = min(max(settings.formatting.tabWidth, 1), 16)
        normalized.formatting.printWidth = min(max(settings.formatting.printWidth, 40), 320)
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
