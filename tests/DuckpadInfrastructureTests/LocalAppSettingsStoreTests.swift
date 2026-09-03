import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Test func localSettingsRoundTripCorruptionAndWriteFailureAreTyped() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckpad-settings-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Settings.json", isDirectory: false)
    let store = LocalAppSettingsStore(archiveURL: archive)
    #expect(try await store.load() == nil)

    let settings = AppSettings(
        appearanceMode: .dark,
        defaultWordWrapEnabled: false,
        defaultWrapMarkerVisible: true
    )
    try await store.save(settings)
    #expect(try await store.load() == settings)
    let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try Data("not-json".utf8).write(to: archive)
    await #expect(throws: AppSettingsStoreError.self) { try await store.load() }

    try FileManager.default.removeItem(at: archive)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
    await #expect(throws: AppSettingsStoreError.self) { try await store.load() }
    await #expect(throws: AppSettingsStoreError.self) { try await store.save(settings) }
}

@Test func localSettingsDescriptorReadAndPublishFailuresRemainCoherent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckpad-settings-authority-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Settings.json", isDirectory: false)
    let original = AppSettings(appearanceMode: .light)
    try await LocalAppSettingsStore(archiveURL: archive).save(original)

    let beforeRename = LocalAppSettingsStore(archiveURL: archive, fault: .beforeRename)
    await #expect(throws: AppSettingsStoreError.writeFailed(
        "injected interruption before settings publish"
    )) {
        try await beforeRename.save(AppSettings(appearanceMode: .dark))
    }
    #expect(try await LocalAppSettingsStore(archiveURL: archive).load() == original)

    let afterRename = LocalAppSettingsStore(archiveURL: archive, fault: .afterRename)
    await #expect(throws: AppSettingsStoreError.writeUncertain(
        "injected interruption after settings publish"
    )) {
        try await afterRename.save(AppSettings(appearanceMode: .dark))
    }
    #expect(try await LocalAppSettingsStore(archiveURL: archive).load()?.appearanceMode == .dark)

    try FileManager.default.removeItem(at: archive)
    let target = root.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: target)
    await #expect(throws: AppSettingsStoreError.self) {
        try await LocalAppSettingsStore(archiveURL: archive).load()
    }

    try FileManager.default.removeItem(at: archive)
    try Data(repeating: 0x20, count: LocalAppSettingsStore.maximumBytes + 1).write(to: archive)
    await #expect(throws: AppSettingsStoreError.corrupt(
        "settings archive exceeds the size limit"
    )) {
        try await LocalAppSettingsStore(archiveURL: archive).load()
    }
}
