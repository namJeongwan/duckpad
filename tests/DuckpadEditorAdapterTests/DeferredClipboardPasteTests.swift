import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadEditorAdapter
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) struct DeferredClipboardPasteTests {
    @Test @MainActor func selectionAndSameBufferPaneChangesInvalidatePendingPaste() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: adapter, editorView: adapter.view,
            secondaryEditorView: adapter.secondaryGroupView, additionalEditorViews: adapter.additionalEditorGroupViews,
            editorGroupRouter: adapter, automaticallyStarts: false)
        defer { controller.close(); adapter.invalidate() }
        controller.start(); await controller.waitForStartup()
        let view = try #require(adapter.activeScintillaView)
        view.insertCommittedText("abcdef")
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        let first = try #require(adapter.capturePasteTargetValidation())
        #expect(first())
        await Task.yield()
        view.setPrimarySelectionUTF8Range(NSRange(location: 3, length: 0))
        #expect(!first())
        let multiple = try #require(adapter.capturePasteTargetValidation())
        #expect(view.addSelectionUTF8Range(NSRange(location: 5, length: 0)))
        #expect(!multiple())
        let pane = try #require(adapter.capturePasteTargetValidation())
        let tab = try #require(workspace.activeFileContext()?.tabID)
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tab, .primary, .primary, .right, .copy))
        for _ in 0..<20 { await Task.yield() }
        #expect(adapter.activeScintillaView !== view)
        #expect(!pane())
        let current = try #require(adapter.capturePasteTargetValidation())
        #expect(current())
    }
}
