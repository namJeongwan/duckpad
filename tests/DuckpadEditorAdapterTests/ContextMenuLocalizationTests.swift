import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadEditorAdapter
import Testing

@Suite(.serialized) @MainActor
struct ContextMenuLocalizationTests {
    @Test func nativeContextMenuUsesAllEightCatalogsAndPreservesUndoActions() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start(); binding.render(workspace.snapshot())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.contentView = nil; window.close() }
        let view = try #require(editor.activeScintillaView)
        func content(_ root: NSView) -> NSView? {
            if NSStringFromClass(type(of: root)).hasSuffix("SCIContentView") { return root }
            return root.subviews.lazy.compactMap { content($0) }.first
        }
        let target = try #require(content(view))
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        let keys = ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All"]
        let ids = ["undo", "redo", "cut", "copy", "paste", "delete", "selectAll"]
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            editor.refreshLocalization(catalog: catalog)
            let menu = try #require(target.menu(for: event))
            let items = menu.items.filter { !$0.isSeparatorItem }
            #expect(items.map(\.title) == keys.map { catalog.text($0) })
            #expect(items.map { $0.identifier?.rawValue } == ids.map { "duckpad.editor.context." + $0 })
            #expect(items.allSatisfy { $0.target != nil && $0.action != nil })
            #expect(items[0].isEnabled == false)
        }
        view.insertCommittedText("한글")
        await workspace.waitForPendingPersistence()
        let undo = try #require(target.menu(for: event)?.items.first { $0.identifier?.rawValue == "duckpad.editor.context.undo" })
        #expect(undo.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(undo.action), to: undo.target, from: undo))
        #expect(view.contentUTF8.isEmpty)
        await workspace.waitForPendingPersistence()
        let redo = try #require(target.menu(for: event)?.items.first { $0.identifier?.rawValue == "duckpad.editor.context.redo" })
        #expect(redo.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(redo.action), to: redo.target, from: redo))
        #expect(view.contentUTF8 == Data("한글".utf8))
        await workspace.waitForPendingPersistence()
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        editor.setReadOnly(true, for: try #require(workspace.snapshot().activeBuffer).bufferID)
        let readOnlyItems = try #require(target.menu(for: event)).items.filter { !$0.isSeparatorItem }
        #expect(readOnlyItems[3].isEnabled) // Copy remains available.
        #expect([0, 1, 2, 4, 5].allSatisfy { !readOnlyItems[$0].isEnabled })
    }
}
