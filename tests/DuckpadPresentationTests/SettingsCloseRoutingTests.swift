import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct SettingsCloseRoutingTests {
    @Test(arguments: [NSEvent.ModifierFlags.control, .command], [false, true])
    func closeShortcutDismissesPreferencesWithoutClosingDocument(modifiers: NSEvent.ModifierFlags, editing: Bool) async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let document = DuckpadWindowController(workspace: workspace,
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            automaticallyStarts: false)
        document.start()
        await document.waitForStartup()
        document.showAndFocus()
        let settings = DuckpadSettingsWindowController()
        let router = AuxiliaryCloseKeyRouter()
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = DuckpadMainMenuFactory.make(target: document)
        router.start()
        defer {
            router.stop()
            NSApp.mainMenu = previousMenu
            settings.close()
            document.close()
        }
        settings.present(settings: .defaults) { .saved($0) }
        let settingsWindow = try #require(settings.window)
        if editing { #expect(settingsWindow.makeFirstResponder(settings.editorFontSize)) }
        let tabIDs = workspace.snapshot().tabs.map(\.id)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: settingsWindow.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        NSApp.sendEvent(event)
        for _ in 0..<20 { await Task.yield() }
        #expect(!settingsWindow.isVisible)
        #expect(document.window?.isVisible == true)
        #expect(workspace.snapshot().tabs.map(\.id) == tabIDs)
        let documentWindow = try #require(document.window)
        let repeated = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: documentWindow.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: true, keyCode: 13))
        NSApp.sendEvent(repeated)
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.snapshot().tabs.map(\.id) == tabIDs)
        let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: documentWindow.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        NSApp.sendEvent(release)
        let next = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: documentWindow.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        NSApp.sendEvent(next)
        for _ in 0..<20 { await Task.yield() }
        if modifiers == .command { #expect(workspace.snapshot().tabs.map(\.id) != tabIDs) }
        else { #expect(workspace.snapshot().tabs.map(\.id) == tabIDs) }
    }
}
