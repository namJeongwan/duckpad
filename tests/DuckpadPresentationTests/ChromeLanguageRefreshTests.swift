import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct ChromeLanguageRefreshTests {
    @Test func languagePreferencesRefreshExistingChromeWithoutReplacingTheEditor() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = TextViewEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
            editorView: editor.scrollView, automaticallyStarts: false)
        defer { controller.close() }
        _ = await workspace.start()
        let buffer = try #require(workspace.snapshot().activeBuffer)
        editor.textView.insertText("Preferences 한글 🦆", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let before = try #require(editor.snapshot(for: buffer.bufferID))
        let selection = editor.textView.selectedRange()
        let undo = editor.textView.undoManager
        #expect(before.text == "Preferences 한글 🦆")
        controller.performToggleWorkspaceSidebar()
        let content = try #require(controller.window?.contentView)
        func sidebar(in view: NSView) -> WorkspaceSidebarView? {
            (view as? WorkspaceSidebarView) ?? view.subviews.lazy.compactMap { sidebar(in: $0) }.first
        }
        let originalSidebar = try #require(sidebar(in: content))
        for language in [AppLanguage.korean, .english, .korean] {
            controller.applyPreferences(AppSettings(appLanguage: language))
            let catalog = LocalizationCatalog(language: language)
            #expect(sidebar(in: content) === originalSidebar)
            #expect(originalSidebar.accessibilityLabel() == catalog.text("Workspace"))
            #expect(controller.statusBar.accessibilityLabel() == catalog.text("Document status"))
            #expect(controller.liveFileBanner.reload.title == catalog.text("Reload from Disk…"))
            #expect(editor.snapshot(for: buffer.bufferID) == before)
            #expect(editor.textView.selectedRange() == selection)
            #expect(editor.textView.undoManager === undo)
            #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
        }
    }
}
