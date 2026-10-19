import Foundation
import DuckpadApplication
import DuckpadDomain
import Testing

@MainActor
private final class AppSettingsStoreFake: AppSettingsStore {
    var loaded: AppSettings?
    var loadFailure: AppSettingsStoreError?
    var saveFailure: AppSettingsStoreError?
    private(set) var saved: [AppSettings] = []

    func load() async throws(AppSettingsStoreError) -> AppSettings? {
        if let loadFailure { throw loadFailure }
        return loaded
    }

    func save(_ settings: AppSettings) async throws(AppSettingsStoreError) {
        if let saveFailure { throw saveFailure }
        saved.append(settings)
    }
}

@Test @MainActor func settingsLoadPublishAndNormalizeCurrentSchema() async {
    let store = AppSettingsStoreFake()
    store.loaded = AppSettings(
        appearanceMode: .dark,
        defaultWordWrapEnabled: false,
        defaultWrapMarkerVisible: true
    )
    let useCase = AppSettingsUseCase(store: store)
    var publications: [AppSettingsState] = []
    useCase.onChange = { publications.append($0) }

    #expect(await useCase.start() == .ready(store.loaded!))
    let proposed = AppSettings(
        schemaVersion: 99,
        appearanceMode: .light,
        defaultWordWrapEnabled: true,
        defaultWrapMarkerVisible: false
    )
    let normalized = AppSettings(
        appearanceMode: .light,
        defaultWordWrapEnabled: true,
        defaultWrapMarkerVisible: false
    )
    #expect(await useCase.update(proposed) == .saved(normalized))
    #expect(store.saved == [normalized])
    #expect(publications == [.ready(store.loaded!), .ready(normalized)])
}

@Test @MainActor func settingsCorruptionFallsBackAndFailedSavePreservesLiveState() async {
    let store = AppSettingsStoreFake()
    store.loadFailure = .corrupt("fixture")
    let useCase = AppSettingsUseCase(store: store)
    #expect(await useCase.start() == .degraded(settings: .defaults, failure: .corrupt("fixture")))

    store.saveFailure = .writeFailed("read only")
    let proposed = AppSettings(appearanceMode: .dark, defaultWordWrapEnabled: false)
    #expect(await useCase.update(proposed) == .failed(.writeFailed("read only")))
    #expect(useCase.state.settings == .defaults)
}

@Test @MainActor func unsupportedSettingsSchemaFallsBackWithoutRewritingStorage() async {
    let store = AppSettingsStoreFake()
    store.loaded = AppSettings(schemaVersion: 7, appearanceMode: .dark)
    let useCase = AppSettingsUseCase(store: store)
    #expect(await useCase.start() == .degraded(settings: .defaults, failure: .unsupportedSchema(7)))
    #expect(store.saved.isEmpty)
}

@Test @MainActor func uncertainSettingsPublishKeepsRuntimeAlignedWithVisibleArchive() async {
    let store = AppSettingsStoreFake()
    store.saveFailure = .writeUncertain("directory sync")
    let useCase = AppSettingsUseCase(store: store)
    let proposed = AppSettings(appearanceMode: .dark, defaultWordWrapEnabled: false)

    #expect(await useCase.update(proposed) == .savedWithWarning(
        settings: proposed,
        failure: .writeUncertain("directory sync")
    ))
    #expect(useCase.state == .degraded(
        settings: proposed,
        failure: .writeUncertain("directory sync")
    ))
}

@Test @MainActor func fontSettingsNormalizeSizeAndKeepLiveReloadChoice() async {
    let store = AppSettingsStoreFake()
    let settings = AppSettingsUseCase(store: store)
    _ = await settings.update(AppSettings(editorFontName: "", editorFontSize: 500, liveFileReloadEnabled: false))
    #expect(settings.state.settings.editorFontName == "Menlo")
    #expect(settings.state.settings.editorFontSize == 72)
    #expect(!settings.state.settings.liveFileReloadEnabled)
    _ = await settings.update(AppSettings(editorFontName: "Monaco", editorFontSize: -1))
    #expect(settings.state.settings.editorFontName == "Monaco")
    #expect(settings.state.settings.editorFontSize == 6)
}

@Test @MainActor func fractionalFontSizesNormalizeAndLegacyIntegersDecode() async throws {
    let store = AppSettingsStoreFake()
    let settings = AppSettingsUseCase(store: store)
    _ = await settings.update(AppSettings(editorFontSize: 18.256))
    #expect(settings.state.settings.editorFontSize == 18.26)
    _ = await settings.update(AppSettings(editorFontSize: .infinity))
    #expect(settings.state.settings.editorFontSize == 13)
    let encoded = try JSONEncoder().encode(AppSettings(editorFontSize: 18))
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded).editorFontSize == 18)
}

@Test @MainActor func editorSpacingBoundsApplyToSavedAndDecodedSettings() async throws {
    let useCase = AppSettingsUseCase(store: AppSettingsStoreFake())
    let invalid = AppSettings(editorLeftPadding: -1, editorRightPadding: .max, editorLineSpacing: .max)
    let expected = AppSettings(editorLeftPadding: 0, editorRightPadding: 32, editorLineSpacing: 20)
    #expect(await useCase.update(invalid) == .saved(expected))
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(invalid)) == expected)
    _ = await useCase.update(AppSettings(editorLeftPadding: .max, editorRightPadding: -1, editorLineSpacing: -1))
    #expect(useCase.state.settings == AppSettings(editorLeftPadding: 32, editorRightPadding: 0, editorLineSpacing: 0))
}

@Test @MainActor func editorConventionsSnippetsSurviveOldSettingsAndRejectStalePanels() async {
    let store = AppSettingsStoreFake()
    let useCase = AppSettingsUseCase(store: store)
    let oldSettings = useCase.state.settings
    let snippets = [TextSnippet(name: "Hello", body: "${1:world}")]
    _ = await useCase.updateSnippets(snippets, expected: [])
    _ = await useCase.update(oldSettings)
    #expect(useCase.state.settings.snippets == snippets)
    if case .failed = await useCase.updateSnippets([], expected: []) {} else { Issue.record("stale panel overwrote snippets") }
    #expect(store.saved.last?.snippets == snippets)
}

@Test @MainActor func shortcutUpdatesPreserveOtherPreferencesAndRejectStaleWriters() async {
    let store = AppSettingsStoreFake()
    let useCase = AppSettingsUseCase(store: store)
    _ = await useCase.start()
    let shortcuts = ["performSelectNextOccurrence:": "cmd+shift+d"]
    guard case .saved = await useCase.updateKeyboardShortcuts(shortcuts, expected: [:]) else {
        Issue.record("shortcut save failed"); return
    }
    var staleSettings = AppSettings.defaults
    staleSettings.editorFontSize = 18
    _ = await useCase.update(staleSettings)
    #expect(useCase.state.settings.keyboardShortcuts == shortcuts)
    #expect(useCase.state.settings.editorFontSize == 18)
    guard case .failed = await useCase.updateKeyboardShortcuts([:], expected: [:]) else {
        Issue.record("stale writer was accepted"); return
    }
    store.saveFailure = .writeFailed("fixture")
    guard case .failed = await useCase.updateKeyboardShortcuts([:], expected: shortcuts) else {
        Issue.record("failed persistence was accepted"); return
    }
    #expect(useCase.state.settings.keyboardShortcuts == shortcuts)
}

@Test @MainActor func minimapPreferencePersistsAndOlderSettingsEnableIt() async throws {
    let defaults = try JSONEncoder().encode(AppSettings.defaults)
    var legacy = try #require(JSONSerialization.jsonObject(with: defaults) as? [String: Any])
    legacy.removeValue(forKey: "minimapVisible")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.minimapVisible)
    let useCase = AppSettingsUseCase(store: AppSettingsStoreFake())
    _ = await useCase.update(AppSettings(minimapVisible: false))
    #expect(!useCase.state.settings.minimapVisible)
    let data = try JSONEncoder().encode(useCase.state.settings)
    #expect(try !JSONDecoder().decode(AppSettings.self, from: data).minimapVisible)
}

@Test @MainActor func minimapMenuPreferencePersistsWithoutChangingOtherSettings() async {
    let store = AppSettingsStoreFake()
    var original = AppSettings.defaults
    original.appearanceMode = .dark
    original.keyboardShortcuts = ["performCopy:": "ctrl+c"]
    store.loaded = original
    let useCase = AppSettingsUseCase(store: store)
    await useCase.start()
    var expected = original
    expected.minimapVisible = false
    #expect(await useCase.updateMinimapVisible(false) == .saved(expected))
    #expect(store.saved.last == expected)
    store.saveFailure = .writeFailed("fixture")
    #expect(await useCase.updateMinimapVisible(true) == .failed(.writeFailed("fixture")))
    #expect(!useCase.state.settings.minimapVisible)
}
