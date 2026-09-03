import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadPresentation
import Testing

private actor SettingsSaveGate {
    private var isOpen = false

    func wait() async {
        while !isOpen { await Task.yield() }
    }

    func open() { isOpen = true }
}

@Test @MainActor func settingsWindowPublishesAccessibleImmediatePreferences() async throws {
    _ = NSApplication.shared
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    var saved: [AppSettings] = []
    controller.present(settings: .defaults) { settings in
        saved.append(settings)
        return .saved(settings)
    }

    let proposed = AppSettings(
        appearanceMode: .dark,
        defaultWordWrapEnabled: false,
        defaultWrapMarkerVisible: true
    )
    await controller.applyForSmoke(proposed)
    #expect(saved == [proposed])
    #expect(controller.smokeState() == DuckpadSettingsSmokeState(
        appearanceMode: .dark,
        defaultWordWrapEnabled: false,
        defaultWrapMarkerVisible: true,
        wrapMarkerControlEnabled: false,
        status: "Saved"
    ))
    let content = try #require(controller.window?.contentView)
    #expect(findView(in: content, identifier: "duckpad.settings.appearance") != nil)
    #expect(findView(in: content, identifier: "duckpad.settings.default-word-wrap") != nil)
    #expect(findView(in: content, identifier: "duckpad.settings.default-wrap-markers") != nil)
    #expect(findView(in: content, identifier: "duckpad.settings.status") != nil)
}

@Test @MainActor func settingsWindowRollsBackControlsWhenPersistenceFails() async {
    _ = NSApplication.shared
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    controller.present(settings: .defaults) { _ in .failed(.writeFailed("fixture")) }
    await controller.applyForSmoke(AppSettings(appearanceMode: .dark, defaultWordWrapEnabled: false))

    let state = controller.smokeState()
    #expect(state.appearanceMode == .system)
    #expect(state.defaultWordWrapEnabled)
    #expect(!state.defaultWrapMarkerVisible)
    #expect(state.wrapMarkerControlEnabled)
    #expect(state.status.contains("Could not save settings"))
}

@Test @MainActor func acceptedSettingsSaveIsJoinedBeforeApplicationTermination() async {
    _ = NSApplication.shared
    let gate = SettingsSaveGate()
    let coordinator = ApplicationTerminationCoordinator()
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    controller.acceptsUpdates = { coordinator.permitsApplicationCommands }
    controller.onUpdateTaskStarted = { coordinator.trackApplicationTask($0) }
    controller.present(settings: .defaults) { settings in
        await gate.wait()
        return .saved(settings)
    }
    controller.submitForSmoke(AppSettings(appearanceMode: .dark))

    var terminationReply: Bool?
    let immediate = coordinator.applicationShouldTerminate { terminationReply = $0 }
    #expect(immediate == .terminateLater)
    #expect(terminationReply == nil)
    await gate.open()
    for _ in 0..<1_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(controller.smokeState().appearanceMode == .dark)
}

@Test @MainActor func failedSettingsSaveRollsBackBeforeApplicationTerminationReply() async {
    _ = NSApplication.shared
    let gate = SettingsSaveGate()
    let coordinator = ApplicationTerminationCoordinator()
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    controller.acceptsUpdates = { coordinator.permitsApplicationCommands }
    controller.onUpdateTaskStarted = { coordinator.trackApplicationTask($0) }
    controller.present(settings: .defaults) { _ in
        await gate.wait()
        return .failed(.writeFailed("fixture"))
    }
    controller.submitForSmoke(AppSettings(appearanceMode: .dark))

    var terminationReply: Bool?
    #expect(coordinator.applicationShouldTerminate { terminationReply = $0 } == .terminateLater)
    #expect(terminationReply == nil)
    await gate.open()
    for _ in 0..<1_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(controller.smokeState().appearanceMode == .system)
    #expect(controller.smokeState().status.contains("Could not save settings"))
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
        if let found = findView(in: child, identifier: identifier) { return found }
    }
    return nil
}
