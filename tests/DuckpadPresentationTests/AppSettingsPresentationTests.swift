import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

private actor ThemeSettingsStore: AppSettingsStore {
    private var settings = AppSettings(defaultWordWrapEnabled: false, defaultWrapMarkerVisible: true)
    func load() async throws(AppSettingsStoreError) -> AppSettings? { settings }
    func save(_ settings: AppSettings) async throws(AppSettingsStoreError) { self.settings = settings }
}

@Test @MainActor func themeMenuChoicePersistsWithoutOpeningSettingsOrChangingEditorDefaults() async throws {
    _ = NSApplication.shared
    let store = ThemeSettingsStore()
    let useCase = AppSettingsUseCase(store: store)
    await useCase.start()
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    controller.configure(settings: useCase.state.settings) { await useCase.update($0) }
    var updateTask: Task<Void, Never>?
    controller.onUpdateTaskStarted = { updateTask = $0 }
    for mode in [AppAppearanceMode.dark, .light, .system] {
        controller.selectAppearance(mode)
        #expect(controller.isUpdating)
        await updateTask?.value
        #expect(!controller.isUpdating)
        #expect(controller.window?.isVisible == false)
        let restored = await AppSettingsUseCase(store: store).start().settings
        #expect(restored.appearanceMode == mode)
        #expect(!restored.defaultWordWrapEnabled)
        #expect(restored.defaultWrapMarkerVisible)
        #expect(controller.smokeState().appearanceMode == mode)
    }
}

@Test @MainActor func themeChoiceCannotRaceAnAcceptedSettingsSave() async {
    _ = NSApplication.shared
    let gate = SettingsSaveGate()
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    var saved: [AppAppearanceMode] = []
    var updateTask: Task<Void, Never>?
    controller.configure(settings: .defaults) { settings in
        await gate.wait()
        saved.append(settings.appearanceMode)
        return .saved(settings)
    }
    controller.onUpdateTaskStarted = { updateTask = $0 }
    controller.selectAppearance(.dark)
    controller.selectAppearance(.light)
    await gate.open()
    await updateTask?.value
    #expect(saved == [.dark])
    #expect(controller.smokeState().appearanceMode == .dark)
}

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
    #expect(state.status.contains("Could not save preferences"))
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
    #expect(controller.smokeState().status.contains("Could not save preferences"))
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
        if let found = findView(in: child, identifier: identifier) { return found }
    }
    return nil
}

@Test @MainActor func preferencesControlsPreserveOtherCategoriesAndRenderInBothAppearances() async throws {
    _ = NSApplication.shared
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    var saved = AppSettings(appearanceMode: .dark, caretWidth: 3, wrapIndentMode: 2)
    var updateTask: Task<Void, Never>?
    controller.onUpdateTaskStarted = { updateTask = $0 }
    controller.present(settings: saved) { value in saved = value; return .saved(value) }
    let root = try #require(controller.window?.contentView)
    func button(_ view: NSView, title: String) -> NSButton? {
        if let candidate = view as? NSButton, candidate.title == title { return candidate }
        return view.subviews.lazy.compactMap { button($0, title: title) }.first
    }
    let toggle = try #require(button(root, title: "Show status bar"))
    // Dispatch the control action directly: performClick's nested AppKit loop
    // can stop Swift's async-main test runner after the test has returned.
    toggle.state = .off
    let action = try #require(toggle.action)
    #expect(NSApplication.shared.sendAction(action, to: toggle.target, from: toggle))
    await updateTask?.value
    #expect(!saved.statusBarVisible)
    #expect(saved.caretWidth == 3 && saved.wrapIndentMode == 2 && saved.appearanceMode == .dark)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        controller.window?.appearance = NSAppearance(named: appearance)
        for category in DuckpadSettingsWindowController.categories {
            controller.selectCategory(category)
            #expect(controller.selectedCategory == category)
            root.layoutSubtreeIfNeeded()

        }
    }
}


@Test @MainActor func fontComboBoxImmediatelyPersistsSelectionAndTypedNames() async throws {
    _ = NSApplication.shared
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    var saved: AppSettings?
    var task: Task<Void, Never>?
    controller.configure(settings: .defaults) { settings in saved = settings; return .saved(settings) }
    controller.onUpdateTaskStarted = { task = $0 }
    let combo = controller.editorFont
    let index = try #require(combo.visibleFonts.firstIndex { $0.family == "Monaco" })
    combo.selectItem(at: index)
    combo.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
    await task?.value
    #expect(saved?.editorFontName == "Monaco")
    combo.stringValue = "menlo"
    let action = try #require(combo.action)
    #expect(NSApp.sendAction(action, to: combo.target, from: combo))
    await task?.value
    #expect(saved?.editorFontName == NSFont(name: "Menlo", size: 13)?.fontName)
    combo.stringValue = "not an installed font"
    #expect(NSApp.sendAction(action, to: combo.target, from: combo))
    #expect(combo.stringValue == "Menlo")
}

@Test @MainActor func fontComboBoxFiltersInstalledFontsAndUsesEachFontForPreview() throws {
    _ = NSApplication.shared
    let combo = EditorFontComboBox()
    var selected: String?
    combo.onFontSelected = { selected = $0 }
    combo.display(fontName: "Menlo")
    #expect(combo.stringValue == "Menlo")
    combo.stringValue = "MONA"
    combo.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
    #expect(!combo.visibleFonts.isEmpty)
    #expect(combo.visibleFonts.allSatisfy { $0.family.localizedStandardContains("mona") || $0.font.fontName.localizedStandardContains("mona") })
    #expect(combo.comboBox(combo, completedString: "mona") == "Monaco")
    #expect(selected == nil)
    let item = try #require(combo.comboBox(combo, objectValueForItemAt: 0) as? NSAttributedString)
    #expect(item.string == "Monaco")
    #expect((item.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == "Monaco")
    combo.stringValue = "does-not-exist"
    combo.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
    #expect(combo.visibleFonts.isEmpty)
    #expect(selected == nil)
    combo.stringValue = ""
    combo.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
    #expect(combo.visibleFonts.count == combo.installedFonts.count)
}

@Test @MainActor func fontComboBoxKeepsNativeMarkedTextOutOfSettings() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let combo = EditorFontComboBox()
    combo.frame = NSRect(x: 10, y: 40, width: 300, height: 26)
    window.contentView?.addSubview(combo)
    combo.display(fontName: "Menlo")
    var selected: String?
    combo.onFontSelected = { selected = $0 }
    #expect(window.makeFirstResponder(combo))
    let editor = try #require(combo.currentEditor() as? NSTextView)
    editor.selectAll(nil)
    editor.insertText("mona", replacementRange: editor.selectedRange())
    #expect(selected == nil)
    #expect(combo.visibleFonts.contains { $0.family == "Monaco" })
    editor.setMarkedText("Monaco", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    #expect(editor.hasMarkedText())
    let index = try #require(combo.visibleFonts.firstIndex { $0.family == "Monaco" })
    combo.selectItem(at: index)
    combo.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
    let action = try #require(combo.action)
    #expect(NSApp.sendAction(action, to: combo.target, from: combo))
    #expect(selected == nil)
    editor.unmarkText()
    combo.stringValue = "Monaco"
    #expect(NSApp.sendAction(action, to: combo.target, from: combo))
    #expect(selected == "Monaco")
}

@Test @MainActor func fontComboBoxKeepsSymbolNamesReadableAndTallPreviewsInsideRows() throws {
    _ = NSApplication.shared
    let symbol = try #require(NSFont(name: "Symbol", size: 14))
    let symbolEntry = EditorFontComboBox.Entry(family: "Symbol", font: symbol)
    #expect(symbolEntry.previewFont.fontName == NSFont.systemFont(ofSize: 14).fontName)
    #expect(symbolEntry.font.fontName == "Symbol")
    let tall = try #require(NSFont(name: "Zapfino", size: 14))
    let preview = EditorFontComboBox.Entry(family: "Zapfino", font: tall).previewFont
    #expect(preview.fontName == tall.fontName)
    #expect(preview.ascender - preview.descender + max(0, preview.leading) <= 22.01)
}
