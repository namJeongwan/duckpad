import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing

@Suite(.serialized)
@MainActor
struct ProgressiveTextLoadingTests {
    @Test func textPreviewKeepsFullRecoveryAndBecomesEditableOnlyAtCompletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        // Exercise UTF-8 and CRLF boundaries across initial and subsequent chunks.
        let text = String(repeating: "  한글🦆abc\r\n", count: 600_000)
        let data = Data(text.utf8)
        try data.write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        var percentages: [Int] = []
        var sawPreview = false
        files.onLoadingProgress = {
            guard let progress = files.loadingProgress else { return }
            percentages.append(progress.percent)
            if progress.loadedByteCount > 0, progress.loadedByteCount < data.count,
               let view = editor.activeScintillaView, let buffer = workspace.snapshot().activeBuffer {
                sawPreview = true
                #expect(view.documentByteLength == UInt(progress.loadedByteCount))
                #expect(!view.isInputEnabled)
                #expect(editor.snapshot(for: buffer.bufferID)?.text == text)
                #expect(editor.recoveryCapture(for: buffer.bufferID)?.baseUTF8 == data)
                let before = view.documentByteLength
                view.insertCommittedText("must not insert")
                #expect(view.documentByteLength == before)
            }
        }
        guard case .opened = await files.open(url) else { Issue.record("open failed"); return }
        #expect(sawPreview)
        #expect(percentages == percentages.sorted())
        #expect(percentages.last == 100)
        #expect(files.loadingProgress == nil)
        let view = try #require(editor.activeScintillaView)
        #expect(view.isInputEnabled)
        #expect(view.contentUTF8 == data)
        #expect(view.lineCount == 600_001)
        #expect(!workspace.snapshot().tabs.contains(where: { $0.isDirty }))
        view.setPrimarySelectionUTF8Range(NSRange(location: data.count, length: 0))
        view.insertCommittedText("new")
        view.undo()
        #expect(view.contentUTF8 == data)
    }

    @Test func retiredPreviewCannotContinueLoading() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let install = try await editor.prepareText(String(repeating: "abc\n", count: 300_000))
        install(buffer)
        editor.display(buffer)
        var retired = false
        do {
            try await editor.finishTextLoad(for: buffer) { loaded, total in
                if loaded < total, !retired {
                    retired = true
                    editor.retire(bufferID: buffer.bufferID)
                }
            }
            Issue.record("retired load completed")
        } catch is CancellationError { }
        #expect(retired)
        #expect(editor.recoveryCapture(for: buffer.bufferID) == nil)
    }

    @Test func cancelledPreviewRemainsRecoverableAndCannotAcceptPartialEdits() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let text = String(repeating: "한글\n", count: 200_000)
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let install = try await editor.prepareText(text)
        install(buffer)
        editor.display(buffer)
        let loading = Task {
            try await editor.finishTextLoad(for: buffer) { _, _ in }
        }
        loading.cancel()
        do { try await loading.value; Issue.record("cancelled load completed") }
        catch is CancellationError { }
        #expect(editor.activeScintillaView?.isInputEnabled == false)
        #expect(editor.snapshot(for: buffer.bufferID)?.text == text)
        #expect(try editor.recoveryCapture(for: buffer.bufferID)?.materializedSnapshot().utf8 == Data(text.utf8))
    }
    @Test func switchingBuffersDoesNotReadWholeNativeDocumentAndPreservesEdits() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "hello"))
        editor.display(first)
        editor.setInputEnabled(true)
        let view = try #require(editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
        view.insertCommittedText("한글")
        let revision = view.revision
        let reads = view.snapshotReadCount
        editor.display(second)
        #expect(view.snapshotReadCount == reads)
        let capture = try #require(editor.recoveryCapture(for: first.bufferID))
        #expect(try capture.materializedSnapshot().utf8 == Data("hello한글".utf8))
        editor.display(.init(bufferID: first.bufferID, revision: revision))
        #expect(editor.activeScintillaView === view)
        view.undo()
        #expect(view.contentUTF8 == Data("hello".utf8))
    }

    @Test func pendingPreviewRejectsProgrammaticMutations() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let text = String(repeating: "original\n", count: 10_000)
        let install = try await editor.prepareText(text)
        install(buffer)
        editor.display(buffer)
        editor.setInputEnabled(true)
        #expect(!editor.isReadyForFormatting(buffer))
        do {
            _ = try editor.captureExtensionInput(tabID: TabID(), expectedBuffer: buffer,
                                                 scope: .document, maximumBytes: 1_000_000)
            Issue.record("extension received a partial document")
        } catch { #expect(error == .staleContext) }
        let view = try #require(editor.activeScintillaView)
        do {
            try view.replaceUTF8Range(NSRange(location: 0, length: 1), withReplacement: Data("Z".utf8),
                                      expectedRevision: 0, resultingRevision: 1)
            Issue.record("native replacement accepted a read-only preview")
        } catch { }

        #expect(editor.replaceActive(range: .init(location: 0, length: 1),
            with: Data("X".utf8), expectedRevision: 0) == .rejected(currentRevision: 0))
        var accepted = false
        #expect(editor.replaceActiveBatch([.init(range: .init(location: 0, length: 1),
            replacementUTF8: Data("Y".utf8))], expectedRevision: 0) { edits in
                accepted = true
                return .accepted(newRevision: UInt64(edits.count))
            } == .rejected(currentRevision: 0))
        #expect(!accepted)
        #expect(editor.activeScintillaView?.revision == 0)
        #expect(try editor.recoveryCapture(for: buffer.bufferID)?.materializedSnapshot().utf8 == Data(text.utf8))
    }

    @Test func splitPreviewFinishesWithOneEditableSharedDocument() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let text = String(repeating: "한글\r\n", count: 30_000)
        let install = try await editor.prepareText(text)
        install(buffer)
        editor.display(buffer)
        editor.setInputEnabled(true)
        let primary = try #require(editor.activeScintillaView)
        editor.setEditorGroupOrientation(.sideBySide)
        editor.display(buffer, in: .secondary)
        #expect(!primary.isInputEnabled)
        try await editor.finishTextLoad(for: buffer) { _, _ in }
        #expect(primary.isInputEnabled)
        #expect(primary.contentUTF8 == Data(text.utf8))
        #expect(primary.revision == 0)
        #expect(primary.changeHistoryState(atLine: 0) == 0)
    }

    @Test func reopeningCancelledFileResumesItsPreview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "abcdef\n", count: 1_300_000)
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        var opening: Task<FileOpenOutcome, Never>?
        files.onLoadingProgress = {
            if let progress = files.loadingProgress, progress.loadedByteCount > 0,
               progress.loadedByteCount < bytes.count { opening?.cancel() }
        }
        opening = Task { await files.open(url) }
        #expect(await opening?.value == .failed(.cancelled))
        let context = try #require(workspace.activeFileContext())
        #expect(editor.hasPendingTextLoad(for: context.buffer.bufferID))
        files.onLoadingProgress = nil
        #expect(await files.open(url) == .activatedExisting(context.tabID))
        #expect(!editor.hasPendingTextLoad(for: context.buffer.bufferID))
        #expect(editor.activeScintillaView?.isInputEnabled == true)
        #expect(editor.activeScintillaView?.contentUTF8 == bytes)
        #expect(files.externalChanges[context.tabID] == nil)
    }

    @Test func replacingPreviewRestoresUndoWithoutExposingPartialText() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let install = try await editor.prepareText(String(repeating: "preview\n", count: 10_000))
        install(buffer)
        editor.display(buffer)
        editor.reload(.init(bufferID: buffer.bufferID, revision: 1, text: "replacement"))
        editor.setInputEnabled(true)
        let view = try #require(editor.activeScintillaView)
        #expect(!editor.hasPendingTextLoad(for: buffer.bufferID))
        #expect(view.contentUTF8 == Data("replacement".utf8))
        #expect(!view.canUndo)
        view.setPrimarySelectionUTF8Range(NSRange(location: 11, length: 0))
        view.insertCommittedText("!")
        #expect(view.canUndo)
        view.undo()
        #expect(view.contentUTF8 == Data("replacement".utf8))
    }

    @Test func replacingPreviewWithBinaryDropsPendingText() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let install = try await editor.prepareText(String(repeating: "preview\n", count: 10_000))
        install(buffer)
        editor.display(buffer)
        let data = Data([0, 1, 2, 3])
        let binary = try await editor.prepareBinary(data)
        binary(buffer)
        #expect(!editor.hasPendingTextLoad(for: buffer.bufferID))
        try await editor.finishBinaryLoad(for: buffer) { _, _ in }
        #expect(editor.activeScintillaView?.contentUTF8 == data)
        #expect(editor.hasBinaryContent(for: buffer.bufferID))
    }

}
