import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@MainActor
struct BinaryLoadingProgressTests {
    private final class Editor: BinaryEditorPort {
        var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
        var readOnlyBuffers = Set<BufferID>()
        var visibleByteCount = 0
        var finishing: CheckedContinuation<Void, any Error>?
        private var complete = Set<BufferID>()
        private var total = 0

        func prepareBinary(_ data: Data) async throws -> @MainActor (EditorBufferDescriptor) -> Void {
            total = data.count
            return { [self] _ in visibleByteCount = 1 }
        }
        func finishBinaryLoad(for buffer: EditorBufferDescriptor,
                              progress: @escaping @MainActor (Int, Int) -> Void) async throws {
            visibleByteCount = total / 2
            progress(visibleByteCount, total)
            try await withCheckedThrowingContinuation { finishing = $0 }
            try Task.checkCancellation()
            visibleByteCount = total
            complete.insert(buffer.bufferID)
            progress(total, total)
        }
        func hasBinaryContent(for bufferID: BufferID) -> Bool { complete.contains(bufferID) }
        func display(_ buffer: EditorBufferDescriptor) {}
        func install(_ snapshot: EditorTextSnapshot) {}
        func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { nil }
        func retire(bufferID: BufferID) { complete.remove(bufferID) }
        func setInputEnabled(_ isEnabled: Bool) {}
        func setReadOnly(_ isReadOnly: Bool, for bufferID: BufferID) {
            if isReadOnly { readOnlyBuffers.insert(bufferID) }
            else { readOnlyBuffers.remove(bufferID) }
        }
        func focus() {}
    }

    @Test func tabIsVisibleAndReadOnlyWhileRemainingBytesLoad() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = Editor()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        var progress: [FileLoadingProgress?] = []
        useCase.onLoadingProgress = { progress.append(useCase.loadingProgress) }
        let opening = Task { await useCase.open(url) }
        while editor.finishing == nil { await Task.yield() }

        let context = try #require(workspace.activeFileContext())
        #expect(context.binding?.isReadOnly == true)
        #expect(editor.readOnlyBuffers.contains(context.buffer.bufferID))
        #expect(editor.visibleByteCount == 4)
        #expect(useCase.loadingProgress?.percent == 50)
        #expect(useCase.loadingProgress?.totalByteCount == 8)
        let initialProgress = try #require(progress.compactMap { $0 }.first)
        #expect(initialProgress.totalByteCount == nil)
        #expect(initialProgress.percent == 0)
        editor.finishing?.resume()
        #expect(await opening.value == .opened(context.tabID))
        #expect(editor.visibleByteCount == 8)
        #expect(progress.contains { $0?.percent == 100 })
        #expect(useCase.loadingProgress == nil)
    }

    @Test(arguments: [false, true])
    func failedOrCancelledLoadsClearProgressAndMarkPartialTabUnavailable(cancel: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2, 3]).write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = Editor()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        let opening = Task { await useCase.open(url) }
        while editor.finishing == nil { await Task.yield() }
        let context = try #require(workspace.activeFileContext())
        if cancel {
            opening.cancel()
            editor.finishing?.resume()
        } else {
            editor.finishing?.resume(throwing: CocoaError(.fileReadUnknown))
        }
        let outcome = await opening.value
        if cancel { #expect(outcome == .failed(.cancelled)) }
        else if case .failed(.store) = outcome { }
        else { Issue.record("expected failed file load") }
        #expect(useCase.loadingProgress == nil)
        #expect(useCase.externalChanges[context.tabID] == .unavailable)
        #expect(workspace.fileContext(tabID: context.tabID)?.binding?.isReadOnly == true)
    }
}
