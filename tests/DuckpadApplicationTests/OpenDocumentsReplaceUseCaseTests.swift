import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@MainActor
private final class ReplacementCaptureEditor: OpenDocumentsReplacementEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var captures: [BufferID: EditorRecoveryCapture] = [:]
    var applied: [BufferID] = []
    func display(_ buffer: EditorBufferDescriptor) {}
    func install(_ snapshot: EditorTextSnapshot) {}
    func reload(_ snapshot: EditorTextSnapshot) {}
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { nil }
    func retire(bufferID: BufferID) {}
    func setInputEnabled(_ isEnabled: Bool) {}
    func setReadOnly(_ isReadOnly: Bool, for bufferID: BufferID) {}
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { nil }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? { captures[bufferID] }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {}
    func selectAndReveal(_ range: SearchUTF8Range) {}
    func activeSelectionUTF8Range() -> SearchUTF8Range? { nil }
    func findActive(_ request: ActiveSearchRequest) throws(SearchFailure) -> SearchUTF8Range? { nil }
    func replaceActive(range: SearchUTF8Range, with replacementUTF8: Data, expectedRevision: UInt64) -> EditorEditOutcome { .rejected(currentRevision: expectedRevision) }
    func replaceActiveBatch(_ edits: [SearchReplacementEdit], expectedRevision: UInt64,
                            accept: ([EditorIncrementalEdit]) -> EditorEditOutcome) -> EditorEditOutcome { .rejected(currentRevision: expectedRevision) }
    func canReplaceBuffer(_ buffer: EditorBufferDescriptor) -> Bool { true }
    func replaceBufferBatch(_ edits: [SearchReplacementEdit], buffer: EditorBufferDescriptor,
                            accept: ([EditorIncrementalEdit]) -> EditorEditOutcome) -> EditorEditOutcome {
        applied.append(buffer.bufferID)
        return accept(edits.enumerated().map { offset, edit in
            EditorIncrementalEdit(bufferID: buffer.bufferID, expectedRevision: buffer.revision + UInt64(offset),
                range: .init(location: edit.range.location, length: edit.range.length),
                replacement: String(decoding: edit.replacementUTF8, as: UTF8.self))
        })
    }
}

@Test @MainActor func openDocumentsReplacementSkipsOversizeCheckpointBeforeUTF8Materialization() async throws {
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    _ = await workspace.start()
    let first = try #require(workspace.snapshot().activeBuffer)
    _ = await workspace.addScratch()
    let second = try #require(workspace.snapshot().activeBuffer)
    let editor = ReplacementCaptureEditor()
    // This deliberately invalid UTF-8 would fail materialization. The smaller
    // size budget must reject it before validation or delta replay can happen.
    editor.captures[first.bufferID] = .init(bufferID: first.bufferID, baseRevision: 0, revision: 0,
                                         baseUTF8: Data(repeating: 0xff, count: 9))
    editor.captures[second.bufferID] = .init(bufferID: second.bufferID, baseRevision: 0, revision: 0,
                                          baseUTF8: Data("duck".utf8))
    let result = try await OpenDocumentsReplaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine(),
        limits: .init(maximumDocumentBytes: 8)).replaceAll(.init(pattern: "duck", replacement: "goose"))
    #expect(result.documents.first?.status == .limitExceeded)
    #expect(result.replacementCount == 1)
    #expect(editor.applied == [second.bufferID])
}

@Test @MainActor func openDocumentsReplacementCorruptCaptureSkipsOnlyItsDocument() async throws {
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    _ = await workspace.start()
    let first = try #require(workspace.snapshot().activeBuffer)
    _ = await workspace.addScratch()
    let second = try #require(workspace.snapshot().activeBuffer)
    let editor = ReplacementCaptureEditor()
    editor.captures[first.bufferID] = .init(bufferID: first.bufferID, baseRevision: 0, revision: 0, baseUTF8: Data([0xff]))
    editor.captures[second.bufferID] = .init(bufferID: second.bufferID, baseRevision: 0, revision: 0, baseUTF8: Data("duck".utf8))
    let result = try await OpenDocumentsReplaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        .replaceAll(.init(pattern: "duck", replacement: "goose"))
    #expect(result.documents.first?.status == .unavailable)
    #expect(result.replacementCount == 1)
    #expect(editor.applied == [second.bufferID])
}

@Test @MainActor func previewRevisionsAndClosedTargetsAreReportedWithoutTouchingNewerBuffers() async throws {
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    _ = await workspace.start()
    let tab = try #require(workspace.snapshot().tabs.first)
    let closed = SearchDocumentResult(tabID: TabID(), title: "closed.txt", matches: [])
    let editor = ReplacementCaptureEditor()
    editor.captures[tab.buffer.bufferID] = .init(bufferID: tab.buffer.bufferID, baseRevision: 0, revision: 0, baseUTF8: Data("duck".utf8))
    let preview = SearchDocumentResult(tabID: tab.id, title: tab.title, matches: [], generatedTitle: tab.generatedTitle)
    let result = try await OpenDocumentsReplaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        .replaceAll(.init(pattern: "duck", replacement: "goose"), only: [tab.id, closed.tabID],
                    expectedRevisions: [tab.buffer.bufferID: 1], expectedDocuments: [preview, closed])
    #expect(result.documents.first { $0.tabID == closed.tabID }?.status == .unavailable)
    #expect(result.documents.first { $0.tabID == tab.id }?.status == .changed)
    #expect(result.replacementCount == 0)
    #expect(editor.applied.isEmpty)
}
