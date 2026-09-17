import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing

private actor GatedPreviewStore: TextFileStore {
    private var reading = false
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    let fail: Bool
    init(fail: Bool) { self.fail = fail }

    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { url }
    func openingPreview(from url: URL, assuming encoding: TextFileEncoding?) async -> FileOpeningPreview? {
        FileOpeningPreview(text: "early sample", totalByteCount: 10_000_000)
    }
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        reading = true
        started?.resume()
        started = nil
        await withCheckedContinuation { gate = $0 }
        if fail { throw .io("injected full-read failure") }
        let bytes = Data("complete verified file".utf8)
        return FileReadResult(data: bytes, identity: FileIdentity(canonicalPath: url.path,
            device: 1, inode: 2, byteCount: UInt64(bytes.count), modifiedNanoseconds: 3, contentToken: "full-read"))
    }
    func waitUntilReading() async {
        if reading { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { gate?.resume(); gate = nil }
    func writeAtomically(_ data: Data, to url: URL, expectedIdentity: FileIdentity?, overwrite: Bool)
        async throws(TextFileStoreError) -> FileWriteReceipt { throw .io("unexpected write") }
}

@Suite(.serialized)
@MainActor
struct FileOpeningPreviewTests {
    init() { _ = NSApplication.shared }

    @Test(arguments: ["success", "failure", "cancel"])
    func prefixIsVisibleBeforeFullReadAndNeverBecomesARecoveryDocument(_ outcome: String) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        let oldView = try #require(editor.activeScintillaView)
        oldView.insertCommittedText("unsaved existing text")
        let oldContext = try #require(workspace.activeFileContext())
        let oldCapture = try #require(editor.recoveryCapture(for: oldContext.buffer.bufferID))
        let tabs = workspace.snapshot().tabs
        let store = GatedPreviewStore(fail: outcome == "failure")
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: store)
        let opening = Task { await files.open(URL(fileURLWithPath: "/tmp/early-preview.txt")) }
        await store.waitUntilReading()
        #expect(editor.openingPreviewByteCount == "early sample".utf8.count)
        #expect(workspace.snapshot().tabs == tabs)
        #expect(files.loadingProgress?.percent == 0)
        #expect(!oldView.isInputEnabled)
        oldView.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
        #expect(!editor.canPerform(.copy))
        #expect(editor.canPerform(.selectAll))
        editor.perform(.selectAll)
        #expect(editor.canPerform(.copy))
        #expect(!editor.canPerform(.cut))
        #expect(editor.activeSelectionUTF8Range() == .init(location: 0, length: 3))
        #expect(!editor.isReadyForFormatting(oldContext.buffer))
        #expect(editor.replaceActive(range: .init(location: 0, length: 1), with: Data("X".utf8),
            expectedRevision: oldContext.buffer.revision) == .rejected(currentRevision: oldContext.buffer.revision))
        #expect(try editor.recoveryCapture(for: oldContext.buffer.bufferID)?.materializedSnapshot().utf8
            == oldCapture.materializedSnapshot().utf8)
        if outcome == "cancel" { opening.cancel() }
        await store.resume()
        let result = await opening.value
        #expect(editor.openingPreviewByteCount == nil)
        #expect(oldView.isInputEnabled)
        if outcome == "success" {
            guard case .opened = result else { Issue.record("open failed: \(result)"); return }
            #expect(editor.activeScintillaView?.contentUTF8 == Data("complete verified file".utf8))
        } else {
            if outcome == "cancel" { #expect(result == .failed(.cancelled)) }
            else { #expect(result == .failed(.store(.io("injected full-read failure")))) }
            #expect(workspace.snapshot().tabs == tabs)
            #expect(editor.activeScintillaView === oldView)
        }
        #expect(try editor.recoveryCapture(for: oldContext.buffer.bufferID)?.materializedSnapshot().utf8
            == oldCapture.materializedSnapshot().utf8)
    }
}
