import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct SearchDialogBookmarkTests {
    @Test func addingMatchingLinesPreservesExistingBookmarksSelectionsAndUndo() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let text = "한글 duck\nother\nduck duck\n끝"
        adapter.install(.init(bufferID: bufferID, revision: 7, text: text))
        adapter.display(.init(bufferID: bufferID, revision: 7))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        #expect(adapter.addBookmarks(on: [1]) == 1)
        #expect(adapter.addBookmarks(on: [-1, 0, 2, 2, 100]) == 2)
        #expect(adapter.addBookmarks(on: [0, 2]) == 2)
        #expect(adapter.recoveryCapture(for: bufferID)?.viewState.bookmarkedLines == [0, 1, 2])
        #expect(adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6))
        #expect(adapter.snapshot(for: bufferID)?.text == text)
        #expect(adapter.snapshot(for: bufferID)?.revision == 7)
        #expect(!view.canUndo)
    }

    @Test func bookmarkTabScansTheActiveDocumentAndPersistsOnlyLineMetadata() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: adapter,
                                                editorView: adapter.view, searchUseCase: search,
                                                automaticallyStarts: false)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        let text = "한글 duck\nother\nduck duck\n끝"
        adapter.install(.init(bufferID: descriptor.bufferID, revision: descriptor.revision, text: text))
        adapter.display(descriptor)
        adapter.addBookmarks(on: [1])
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        controller.performShowFind()
        controller.searchPanel.show(tab: .bookmarks, selectedText: "duck")
        controller.searchPanel.onMarkAll?(controller.searchPanel.currentQuery(), false)
        for _ in 0..<100 {
            if adapter.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [0, 1, 2] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [0, 1, 2])
        controller.searchPanel.onMarkAll?(controller.searchPanel.currentQuery(), true)
        for _ in 0..<100 {
            if adapter.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [0, 2] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [0, 2])
        #expect(adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6))
        #expect(adapter.snapshot(for: descriptor.bufferID)?.text == text)
        #expect(workspace.snapshot().activeBuffer == descriptor)
        #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == false)
        #expect(!view.canUndo)
        controller.searchPanel.onClearBookmarks?()
        #expect(!adapter.hasBookmarks)
    }
    @Test func bookmarkLimitKeepsExistingLinesAndReportsTheAcceptedCount() {
        let adapter = ScintillaEditorAdapter()
        let id = BufferID()
        let limit = EditorViewState.maximumBookmarkCount
        adapter.install(.init(bufferID: id, revision: 0, text: String(repeating: "duck\n", count: limit + 1)))
        adapter.display(.init(bufferID: id, revision: 0))
        #expect(adapter.addBookmarks(on: [limit]) == 1)
        #expect(adapter.addBookmarks(on: Array(0...limit)) == limit)
        let lines = adapter.recoveryCapture(for: id)?.viewState.bookmarkedLines ?? []
        #expect(lines.count == limit)
        #expect(lines.contains(limit))
        #expect(!lines.contains(limit - 1))
    }

    @Test func textViewBookmarkAdditionPreservesSelectionAndRevision() {
        let adapter = TextViewEditorAdapter()
        let id = BufferID()
        adapter.install(.init(bufferID: id, revision: 4, text: "duck\n한글\nduck"))
        adapter.display(.init(bufferID: id, revision: 4))
        adapter.textView.setSelectedRange(NSRange(location: 0, length: 4))
        adapter.addBookmarks(on: [1])
        #expect(adapter.addBookmarks(on: [-1, 0, 2, 2, 9]) == 2)
        #expect(adapter.recoveryCapture(for: id)?.viewState.bookmarkedLines == [0, 1, 2])
        #expect(adapter.textView.selectedRange() == NSRange(location: 0, length: 4))
        #expect(adapter.snapshot(for: id)?.revision == 4)
        #expect(adapter.textView.undoManager?.canUndo != true)
    }

}
