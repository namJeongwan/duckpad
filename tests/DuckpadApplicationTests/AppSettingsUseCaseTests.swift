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
