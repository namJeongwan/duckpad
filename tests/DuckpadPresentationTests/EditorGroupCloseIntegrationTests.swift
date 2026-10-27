import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct EditorGroupCloseIntegrationTests {
    @Test(arguments: [EditorGroupID.primary, .secondary])
    func closingOneSharedNativeViewRetainsDirtyBytesAndUndo(group: EditorGroupID) async throws {
        var session = ScratchSession()
        session.addUntitled(); session.addUntitled()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
        let editor = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace,
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            editorAdapter: editor, editorView: editor.view, secondaryEditorView: editor.secondaryGroupView,
            editorGroupRouter: editor, automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        controller.start(); await controller.waitForStartup()
        _ = await workspace.addScratch()
        let tab = try #require(workspace.snapshot().tabs.last)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let view = controller.editorGroupWorkspace
        #expect(view.performEdgeDrop(payload: .init(tabID: tab.id, sourceGroup: .primary),
            location: NSPoint(x: view.dropOverlay.bounds.maxX - 2, y: view.dropOverlay.bounds.midY), optionPressed: true))
        let secondary = try #require(editor.activeScintillaView)
        secondary.insertCommittedText("한글 shared edit")
        controller.editorGroupWorkspace.onAction?(.select(tab.id, group))
        controller.performCloseActiveTab()
        for _ in 0..<100 {
            let layout = controller.editorGroupLayoutSnapshot
            if layout.visibleGroups.filter({ layout.tabIDs(in: $0).contains(tab.id) }).count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let layout = controller.editorGroupLayoutSnapshot
        let remaining = try #require(layout.visibleGroups.first { layout.tabIDs(in: $0).contains(tab.id) })
        #expect(layout.visibleGroups.filter { layout.tabIDs(in: $0).contains(tab.id) }.count == 1)
        #expect(workspace.snapshot().tabs.first { $0.id == tab.id }?.isDirty == true)
        controller.editorGroupWorkspace.onAction?(.select(tab.id, remaining))
        let retained = try #require(editor.activeScintillaView)
        #expect(retained.contentUTF8 == Data("한글 shared edit".utf8))
        #expect(retained.canUndo)
        retained.undo()
        #expect(retained.contentUTF8.isEmpty)
        retained.redo()
        #expect(retained.contentUTF8 == Data("한글 shared edit".utf8))
    }
}
