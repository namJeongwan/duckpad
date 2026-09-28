import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

private actor FindRoutingStore: SessionStore {
    func loadSession() async throws(SessionStoreError) -> StoredSession? { nil }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult { .committed }
}

@Suite(.serialized) @MainActor
struct FindClipboardRoutingTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test(arguments: ["duckpad.search.find", "duckpad.search.replace"])
    func pasteTargetsFocusedSearchInput(fieldID: String) async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: FindRoutingStore())
        let editor = TextViewEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace,
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            editorAdapter: editor, editorView: editor.scrollView, automaticallyStarts: false)
        defer { controller.performCloseFindPanel(); controller.close() }
        controller.start(); await controller.waitForStartup()
        controller.showWindow(nil)
        editor.textView.insertText("original body", replacementRange: NSRange(location: 0, length: 0))
        let revision = workspace.snapshot().activeBuffer?.revision
        controller.performShowReplace()
        let field = try #require(descendants(controller.searchPanel).first { $0.accessibilityIdentifier() == fieldID } as? NSTextField)
        let panel = try #require(field.window)
        // Swift Testing has no running NSApplication event loop/key window.
        // Use the real panel's field editor as the command window explicitly.
        controller.editingCommandWindow = { panel }
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.makeFirstResponder(field))
        let input = try #require(panel.firstResponder as? NSTextView)
        input.allowsUndo = true
        input.string = "needle"; input.setSelectedRange(NSRange(location: 0, length: 6))
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item })
        }
        board.clearContents(); board.setString("한글 pasted", forType: .string)
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let paste = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == #selector(DuckpadWindowController.performPaste(_:)) })
        #expect(controller.validateMenuItem(paste))
        let undo = try #require(input.undoManager)
        undo.beginUndoGrouping()
        #expect(NSApp.sendAction(try #require(paste.action), to: paste.target, from: paste))
        undo.endUndoGrouping()
        #expect(input.string == "한글 pasted")
        #expect(editor.textView.string == "original body")
        #expect(workspace.snapshot().activeBuffer?.revision == revision)
        controller.performUndo()
        #expect(input.string == "needle")
        #expect(editor.textView.string == "original body")
        controller.performRedo()
        #expect(input.string == "한글 pasted")
        editor.setInputEnabled(false)
        #expect(controller.validateMenuItem(paste))
        editor.setInputEnabled(true)
        input.isEditable = false
        #expect(!controller.validateMenuItem(paste))
        controller.performPaste()
        #expect(input.string == "한글 pasted")
        #expect(editor.textView.string == "original body")
        input.isEditable = true
        controller.performDuplicateLine()
        #expect(editor.textView.string == "original body")
        controller.performSelectAll()
        controller.performCopy()
        #expect(board.string(forType: .string) == "한글 pasted")
        #expect(input.selectedRange() == NSRange(location: 0, length: (input.string as NSString).length))
        controller.performCut()
        #expect(input.string.isEmpty)
        #expect(editor.textView.string == "original body")
        controller.performCloseFindPanel()
        controller.editingCommandWindow = { [weak controller] in controller?.window }
        controller.window?.makeKeyAndOrderFront(nil)
        editor.focus()
        controller.performPaste()
        #expect(editor.textView.string.contains("한글 pasted"))
    }
}
