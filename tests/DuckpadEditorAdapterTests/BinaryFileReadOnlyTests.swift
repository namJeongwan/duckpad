import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
@MainActor
struct BinaryFileReadOnlyTests {
    @Test func binaryOpenRejectsEditsAndEverySaveRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("binary.bin")
        var original = Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
        for offset in stride(from: 63, to: original.count, by: 64) { original[offset] = 0x0A }
        original.replaceSubrange(0..<4, with: [0, 0x80, 0xFF, 0x41])
        original.append(contentsOf: [0xFF, 0x54, 0x41, 0x49, 0x4C])
        try original.write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json")))
        guard case .opened(let tabID) = await files.open(url) else {
            Issue.record("Binary file did not open"); return
        }
        let native = try #require(editor.activeScintillaView)
        let contents = native.contentUTF8
        #expect(contents == original)
        #expect(!native.isInputEnabled)
        native.insertCommittedText("changed")
        #expect(native.contentUTF8 == contents)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        #expect(editor.snapshot(for: buffer.bufferID) == nil)
        #expect(workspace.acceptEditorEdit(.init(bufferID: buffer.bufferID,
            expectedRevision: buffer.revision, range: .init(location: 0, length: 0),
            replacement: "changed")) == .rejected(currentRevision: buffer.revision))
        let reservation = await workspace.reserveEditorBatch(bufferID: buffer.bufferID,
            expectedRevision: buffer.revision, editCount: 1)
        #expect(reservation == nil)
        if let reservation { workspace.cancelEditorBatch(reservation) }
        guard case .failed = await files.saveActive() else { Issue.record("Save was allowed"); return }
        guard case .failed = await files.saveAs(root.appendingPathComponent("saved.bin")) else {
            Issue.record("Save As was allowed"); return
        }
        guard case .failed = await files.saveCopy(root.appendingPathComponent("copy.bin")) else {
            Issue.record("Save Copy was allowed"); return
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("saved.bin").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.bin").path))
        #expect(workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == false)

        _ = await workspace.addScratch()
        let scratch = try #require(editor.activeScintillaView)
        #expect(scratch.isInputEnabled)
        scratch.insertCommittedText("editable")
        #expect(scratch.contentUTF8 == Data("editable".utf8))
        _ = await workspace.activate(tabID: tabID)
        editor.setInputEnabled(false)
        editor.setInputEnabled(true)
        #expect(editor.activeScintillaView?.isInputEnabled == false)
        #expect(editor.activeScintillaView?.contentUTF8 == contents)

        editor.setEditorGroupOrientation(.sideBySide)
        editor.display(buffer, in: .secondary)
        #expect(editor.activeScintillaView?.isInputEnabled == false)
        #expect(!editor.canPerform(.cut))
        #expect(!editor.canPerform(.paste))
        editor.perform(.selectAll)
        #expect(editor.canPerform(.copy))

        _ = await workspace.close(tabID: tabID)
        guard case .opened(let reopenedID) = await files.open(url) else {
            Issue.record("Binary did not reopen"); return
        }
        let tabCount = workspace.snapshot().tabs.count
        _ = await workspace.restoreLastClosedTab()
        #expect(workspace.snapshot().tabs.count == tabCount)
        #expect(workspace.activeFileContext()?.tabID == reopenedID)
        #expect(workspace.activeFileContext()?.binding?.isReadOnly == true)
        #expect(editor.activeScintillaView?.isInputEnabled == false)
        let restoredBuffer = try #require(workspace.snapshot().activeBuffer)

        let persistedSession = try JSONEncoder().encode(workspace.recoverySession())
        let restoredWorkspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let restoredEditor = ScintillaEditorAdapter()
        defer { restoredEditor.invalidate() }
        let restoredBinding = EditorBindingUseCase(workspace: restoredWorkspace, editor: restoredEditor)
        restoredWorkspace.onChange = { restoredBinding.render($0) }
        editor.activeScintillaView?.restoreCaretUTF8Position(UInt(contents.count - 2),
            anchorPosition: UInt(contents.count - 2), firstVisibleLine: 100,
            horizontalScrollOffset: 0, wordWrapEnabled: false)
        let capture = try #require(editor.recoverySnapshot(for: restoredBuffer.bufferID))
        _ = await restoredWorkspace.start(restoring: StoredSession(
            session: try JSONDecoder().decode(ScratchSession.self, from: persistedSession),
            generation: .init(rawValue: 1))) {
                restoredEditor.installRecovery(capture)
            }
        #expect(restoredWorkspace.activeFileContext()?.binding?.isReadOnly == true)
        #expect(restoredEditor.activeScintillaView?.isInputEnabled == false)
        #expect(capture.utf8.isEmpty)
        let restoredFiles = FileDocumentUseCase(workspace: restoredWorkspace, editor: restoredEditor,
            store: LocalTextFileStore())
        #expect(await restoredFiles.restoreSecurityScopedAccessForOpenDocuments().isEmpty)
        #expect(restoredEditor.activeScintillaView?.contentUTF8 == contents)
        #expect(restoredEditor.activeScintillaView?.caretUTF8Position == UInt(contents.count - 2))

        let controller = DuckpadWindowController(workspace: restoredWorkspace,
            editorAdapter: restoredEditor, editorView: restoredEditor.view,
            fileUseCase: FileDocumentUseCase(workspace: restoredWorkspace, editor: restoredEditor,
                store: LocalTextFileStore()), automaticallyStarts: false)
        defer { controller.close() }
        for action in [#selector(DuckpadWindowController.performSaveFile(_:)),
                       #selector(DuckpadWindowController.performSaveFileAs(_:)),
                       #selector(DuckpadWindowController.performSaveCopyAs(_:))] {
            #expect(!controller.validateMenuItem(NSMenuItem(title: "save", action: action, keyEquivalent: "")))
        }
    }
    @Test func recoveredEmptyTextKeepsItsCurrentViewState() throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.installRecovery(EditorRecoverySnapshot(bufferID: buffer.bufferID, revision: 0,
            utf8: Data(), viewState: EditorViewState()))
        editor.setReadOnly(false, for: buffer.bufferID)
        editor.display(buffer)
        let native = try #require(editor.activeScintillaView)
        native.zoomLevel = 3
        #expect(editor.recoveryCapture(for: buffer.bufferID)?.viewState.zoomLevel == 3)
    }

    @Test func explicitTextEncodingUsesFullIdentityForPreparedBinaryBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x41, 0, 0x42, 0]).write(to: url)
        let store = LocalTextFileStore()
        let prepared = try await store.readForDisplay(from: url, assuming: nil)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = TextViewEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: store)
        guard case .opened = await files.open(WorkspaceFileRead(url: url, result: prepared),
            assuming: .utf16LittleEndian) else { Issue.record("Explicit text did not open"); return }
        #expect(workspace.activeFileContext()?.binding?.isReadOnly == false)
        #expect(workspace.activeFileContext()?.binding?.observedIdentity == (try await store.read(from: url).identity))
    }

    @Test func explicitEncodingCannotMakeAPartialPreparedReadEditable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 1_024 * 1_024 + 2).write(to: url)
        let store = LocalTextFileStore()
        let full = try await store.readForDisplay(from: url, assuming: nil)
        let read = FileReadResult(data: Data(full.data.prefix(1_024 * 1_024)), identity: full.identity)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = TextViewEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: store)
        guard case .failed = await files.open(WorkspaceFileRead(url: url, result: read),
            assuming: .utf16LittleEndian) else { Issue.record("Partial read was accepted"); return }

    }

}
