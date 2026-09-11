import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import Foundation
import Testing

@Suite(.serialized)
struct LiveFileReloadIntegrationTests {
    @Test(arguments: [false, true]) @MainActor
    func externalSavesPreserveUndoHistory(reopenWithEncoding: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let monitor = LocalFileChangeMonitor(interval: .milliseconds(15))
        defer { monitor.stop() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json")),
            changeMonitor: monitor)
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
            editorView: editor.view, fileUseCase: files)
        defer { controller.window?.close() }
        controller.applyPreferences(AppSettings(liveFileReloadEnabled: !reopenWithEncoding))
        _ = await workspace.start()
        guard case .opened(let id) = await files.open(url) else {
            Issue.record("open failed")
            return
        }
        let view = try #require(editor.activeScintillaView)
        view.insertCommittedText("Duckpad edit ")
        #expect(await files.saveActive() == .saved(id))
        #expect(try Data(contentsOf: url) == view.contentUTF8)
        let locallySaved = view.contentUTF8
        for atomic in [false, true] {
            let text = atomic ? "atomic 한글 🦆" : "in-place 한글 🦆"
            try Data(text.utf8).write(to: url, options: atomic ? .atomic : [])
            if reopenWithEncoding {
                #expect(await files.open(url, assuming: .utf8) == .activatedExisting(id))
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while view.contentUTF8 != Data(text.utf8), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(view.contentUTF8 == Data(text.utf8))
            #expect(workspace.snapshot().tabs.first(where: { $0.id == id })?.isDirty == false)
            #expect(files.externalChanges.isEmpty)
        }
        files.setLiveReloadEnabled(false)
        await files.waitForLiveReload()
        // Replacing the file with identical bytes must not add an undo step.
        try Data("atomic 한글 🦆".utf8).write(to: url, options: .atomic)
        await files.refreshFromDisk(tabID: id)
        for expected in [Data("in-place 한글 🦆".utf8), locallySaved, Data("before".utf8)] {
            #expect(view.canUndo)
            view.undo()
            #expect(view.contentUTF8 == expected)
            #expect(workspace.snapshot().tabs.first(where: { $0.id == id })?.isDirty == true)
            #expect(view.revision == workspace.fileContext(tabID: id)?.buffer.revision)
            #expect(try editor.recoveryCapture(for: workspace.fileContext(tabID: id)!.buffer.bufferID)?.materializedSnapshot().utf8 == expected)
        }
        for expected in [locallySaved, Data("in-place 한글 🦆".utf8), Data("atomic 한글 🦆".utf8)] {
            #expect(view.canRedo)
            view.redo()
            #expect(view.contentUTF8 == expected)
            #expect(view.revision == workspace.fileContext(tabID: id)?.buffer.revision)
        }
        #expect(try Data(contentsOf: url) == Data("atomic 한글 🦆".utf8))

        view.insertCommittedText("unsaved ")
        let unsaved = view.contentUTF8
        try Data().write(to: url, options: .atomic)
        guard case .conflict = await files.saveActive() else {
            Issue.record("external change did not produce a save conflict")
            return
        }
        #expect(await files.resolveConflict(.reload) == .saved(id))
        #expect(view.contentUTF8.isEmpty)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == id })?.isDirty == false)
        view.undo()
        #expect(view.contentUTF8 == unsaved)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == id })?.isDirty == true)
        view.redo()
        #expect(view.contentUTF8.isEmpty)
        #expect(try Data(contentsOf: url).isEmpty)
    }
}
