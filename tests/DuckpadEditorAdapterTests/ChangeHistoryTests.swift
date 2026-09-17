import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct ChangeHistoryTests {
    init() { _ = NSApplication.shared }

    @Test func editsUndoSaveAndRedoTrackLineChangesWithoutReadingSnapshots() throws {
        let view = DPScintillaEditorView(frame: .zero)
        defer { view.invalidate() }
        try view.loadUTF8(Data("first\nsecond\nthird".utf8), revision: 1)
        #expect((0..<3).allSatisfy { view.changeHistoryState(atLine: UInt($0)) == 0 })
        let reads = view.snapshotReadCount
        view.setPrimarySelectionUTF8Range(NSRange(location: 6, length: 0))
        view.beginGroupedUndo()
        view.insertCommittedText("edited ")
        view.endGroupedUndo()
        #expect(view.changeHistoryState(atLine: 0) == 0)
        #expect(view.changeHistoryState(atLine: 1) & 4 != 0)
        view.undo()
        #expect(view.changeHistoryState(atLine: 1) == 0)
        view.redo()
        #expect(view.changeHistoryState(atLine: 1) & 4 != 0)
        view.recordSavePoint(atRevision: view.revision)
        #expect(view.changeHistoryState(atLine: 1) & 2 != 0)
        #expect(view.changeHistoryState(atLine: 1) & 4 == 0)
        #expect(view.canUndo)
        view.undo()
        #expect(view.changeHistoryState(atLine: 1) & 1 != 0)
        view.redo()
        #expect(view.changeHistoryState(atLine: 1) & 2 != 0)
        #expect(view.snapshotReadCount == reads)
    }

    @Test func deletionCloneAndThemePreserveMarkersAndNewLoadResetsThem() throws {
        let view = DPScintillaEditorView(frame: .zero)
        let clone = DPScintillaEditorView(frame: .zero)
        defer { clone.invalidate(); view.invalidate() }
        try view.loadUTF8(Data("first\nsecond\nthird".utf8), revision: 4)
        clone.shareDocument(with: view)
        view.setPrimarySelectionUTF8Range(NSRange(location: 6, length: 7))
        view.beginGroupedUndo()
        view.deleteSelectionOrNextCharacter()
        view.endGroupedUndo()
        #expect(view.changeHistoryState(atLine: 1) & 4 != 0)
        #expect(clone.changeHistoryState(atLine: 1) == view.changeHistoryState(atLine: 1))
        clone.apply(.dark)
        #expect(clone.changeHistoryState(atLine: 1) & 4 != 0)
        view.undo()
        #expect(view.changeHistoryState(atLine: 1) == 0)
        try view.loadUTF8(Data("fresh".utf8), revision: 10)
        #expect(view.changeHistoryState(atLine: 0) == 0)
        #expect(!view.canUndo)
    }

    @Test func staleSaveCannotMarkNewerEditsSaved() throws {
        let view = DPScintillaEditorView(frame: .zero)
        defer { view.invalidate() }
        try view.loadUTF8(Data("first".utf8), revision: 7)
        view.insertCommittedText("edited ")
        view.recordSavePoint(atRevision: 6)
        #expect(view.changeHistoryState(atLine: 0) & 4 != 0)
    }

    @Test func adapterForwardsMatchingSavePointToTheBuffer() throws {
        let adapter = ScintillaEditorAdapter()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 1)
        adapter.install(.init(bufferID: descriptor.bufferID, revision: 1, text: "first"))
        adapter.display(descriptor)
        let view = try #require(adapter.activeScintillaView)
        view.insertCommittedText("edit ")
        #expect(view.changeHistoryState(atLine: 0) & 4 != 0)
        adapter.recordSavePoint(for: descriptor.bufferID, revision: view.revision)
        #expect(view.changeHistoryState(atLine: 0) & 2 != 0)
    }
}
