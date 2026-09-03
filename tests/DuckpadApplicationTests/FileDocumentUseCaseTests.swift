import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

private actor FileStoreFake: TextFileStore {
    private var files: [String: FileReadResult] = [:]
    private var serial: UInt64 = 0
    private(set) var readCount = 0
    private var blockNextWrite = false
    private var blockedWriteEntered = false
    private var releaseBlockedWrite = false
    private var blockNextRead = false
    private var blockedReadEntered = false
    private var releaseBlockedRead = false
    private var forcedWriteError: TextFileStoreError?

    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL {
        url.standardizedFileURL
    }

    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        readCount += 1
        if blockNextRead {
            blockNextRead = false
            blockedReadEntered = true
            while !releaseBlockedRead { await Task.yield() }
        }
        guard let file = files[url.standardizedFileURL.path] else { throw .notFound(url.path) }
        return file
    }

    func writeAtomically(_ data: Data, to url: URL, expectedIdentity: FileIdentity?, overwrite: Bool) async throws(TextFileStoreError) -> FileWriteReceipt {
        if let forcedWriteError { throw forcedWriteError }
        if blockNextWrite {
            blockNextWrite = false
            blockedWriteEntered = true
            while !releaseBlockedWrite { await Task.yield() }
        }
        let path = url.standardizedFileURL.path
        let current = files[path]
        if let expectedIdentity {
            guard current?.identity == expectedIdentity else { throw .conflict(current: current?.identity) }
        } else if current != nil && !overwrite {
            throw .conflict(current: current?.identity)
        }
        serial += 1
        let identity = makeIdentity(path: path, data: data, serial: serial)
        files[path] = FileReadResult(data: data, identity: identity)
        return FileWriteReceipt(identity: identity)
    }

    func seed(_ text: String, at url: URL, encoding: TextFileEncoding = .utf8, bom: ByteOrderMark = .absent) {
        serial += 1
        let data = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: bom)
        let path = url.standardizedFileURL.path
        files[path] = FileReadResult(data: data, identity: makeIdentity(path: path, data: data, serial: serial))
    }

    func externalReplace(_ text: String, at url: URL) { seed(text, at: url) }
    func text(at url: URL) -> String? { files[url.standardizedFileURL.path].flatMap { String(data: $0.data, encoding: .utf8) } }
    func data(at url: URL) -> Data? { files[url.standardizedFileURL.path]?.data }
    func result(at url: URL) -> FileReadResult? { files[url.standardizedFileURL.path] }
    func setWriteError(_ error: TextFileStoreError?) { forcedWriteError = error }
    func armBlockedWrite() { blockNextWrite = true; blockedWriteEntered = false; releaseBlockedWrite = false }
    func waitForBlockedWrite() async { while !blockedWriteEntered { await Task.yield() } }
    func releaseWrite() { releaseBlockedWrite = true }
    func armBlockedRead() { blockNextRead = true; blockedReadEntered = false; releaseBlockedRead = false }
    func waitForBlockedRead() async { while !blockedReadEntered { await Task.yield() } }
    func releaseRead() { releaseBlockedRead = true }

    private func makeIdentity(path: String, data: Data, serial: UInt64) -> FileIdentity {
        FileIdentity(canonicalPath: path, device: 1, inode: 1, byteCount: UInt64(data.count), modifiedNanoseconds: Int64(serial), contentToken: "token-\(serial)-\(data.count)")
    }
}

@MainActor
private final class FileEditorFake: EditorPort, EditorSelectionPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    private var active: EditorBufferDescriptor?
    private var values: [BufferID: EditorTextSnapshot] = [:]
    private(set) var revealedRange: SearchUTF8Range?
    func display(_ buffer: EditorBufferDescriptor) {
        active = buffer
        let text = values[buffer.bufferID]?.text ?? ""
        values[buffer.bufferID] = EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: text)
    }
    func install(_ snapshot: EditorTextSnapshot) {
        values[snapshot.bufferID] = snapshot
        if active?.bufferID == snapshot.bufferID { active = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision) }
    }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { values[bufferID] }
    func retire(bufferID: BufferID) { values.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func selectAndReveal(_ range: SearchUTF8Range) { revealedRange = range }
    @discardableResult
    func replaceWith(_ text: String) -> EditorEditOutcome? {
        guard let active, let old = values[active.bufferID] else { return nil }
        let edit = EditorIncrementalEdit(bufferID: active.bufferID, expectedRevision: active.revision, range: TextEditRange(location: 0, length: old.text.utf8.count), replacement: text)
        let outcome = onEdit?(edit)
        guard case .accepted(let revision) = outcome else { return outcome }
        self.active = EditorBufferDescriptor(bufferID: active.bufferID, revision: revision)
        values[active.bufferID] = EditorTextSnapshot(bufferID: active.bufferID, revision: revision, text: text)
        return outcome
    }
}

@Test @MainActor func duplicateCanonicalOpenActivatesExistingDocument() async {
    let sessionStore = FileSessionStoreFake()
    let workspace = ScratchWorkspaceUseCase(store: sessionStore)
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    _ = binding
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-duplicate.txt")
    await files.seed("한글🙂", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    guard case .opened(let first) = await useCase.open(url) else { Issue.record("first open failed"); return }
    guard case .activatedExisting(let second) = await useCase.open(url) else { Issue.record("duplicate was not activated"); return }
    #expect(first == second)
    #expect(workspace.snapshot().tabs.count == 2)
    #expect(await files.readCount == 1)
}

@Test @MainActor func workspaceDescriptorReadOpensWithoutASecondPathRead() async throws {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-workspace-prepared.txt")
    let data = Data("descriptor-safe 한글🙂".utf8)
    let identity = FileIdentity(
        canonicalPath: url.path,
        device: 7,
        inode: 9,
        byteCount: UInt64(data.count),
        modifiedNanoseconds: 11,
        contentToken: "prepared"
    )
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)

    let outcome = await useCase.open(WorkspaceFileRead(
        url: url,
        result: FileReadResult(data: data, identity: identity)
    ))
    guard case .opened = outcome else {
        Issue.record("prepared workspace read did not open: \(outcome)")
        return
    }
    #expect(await files.readCount == 0)
    #expect(workspace.activeFileContext()?.binding?.observedIdentity == identity)
    let bufferID = try #require(workspace.snapshot().activeBuffer?.bufferID)
    #expect(editor.snapshot(for: bufferID)?.text == "descriptor-safe 한글🙂")
}

@Test @MainActor func folderSearchResultOpensExactIdentityAndRevealsUTF8Range() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-folder-result.txt")
    await files.seed("한글 duck", at: url)
    guard let read = await files.result(at: url) else { Issue.record("fixture unavailable"); return }
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let match = FolderSearchMatch(
        range: SearchUTF8Range(location: 7, length: 4),
        line: 1,
        column: 8,
        snippet: "한글 duck"
    )
    let document = FolderSearchDocumentResult(
        path: url.path, relativePath: "duckpad-folder-result.txt",
        identity: read.identity, matches: [match]
    )

    guard case .activated(let tabID) = await useCase.activateFolderSearchMatch(document: document, match: match) else {
        Issue.record("folder result did not activate")
        return
    }
    #expect(workspace.activeFileContext()?.tabID == tabID)
    #expect(editor.revealedRange == match.range)
}

@Test @MainActor func folderSearchResultRejectsDirtyOpenDocumentWithoutMovingSelection() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-folder-dirty.txt")
    await files.seed("duck disk", at: url)
    guard let read = await files.result(at: url) else { Issue.record("fixture unavailable"); return }
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("local dirty")
    let match = FolderSearchMatch(
        range: SearchUTF8Range(location: 0, length: 4),
        line: 1,
        column: 1,
        snippet: "duck disk"
    )
    let document = FolderSearchDocumentResult(
        path: url.path, relativePath: "duckpad-folder-dirty.txt",
        identity: read.identity, matches: [match]
    )

    #expect(await useCase.activateFolderSearchMatch(document: document, match: match) == .stale(url.path))
    #expect(editor.revealedRange == nil)
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "local dirty")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
}

@Test @MainActor func folderSearchResultRejectsFileChangedAfterSearch() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-folder-stale-disk.txt")
    await files.seed("duck old", at: url)
    guard let searched = await files.result(at: url) else { Issue.record("fixture unavailable"); return }
    await files.externalReplace("new contents", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let match = FolderSearchMatch(
        range: SearchUTF8Range(location: 0, length: 4),
        line: 1,
        column: 1,
        snippet: "duck old"
    )
    let document = FolderSearchDocumentResult(
        path: url.path, relativePath: "duckpad-folder-stale-disk.txt",
        identity: searched.identity, matches: [match]
    )

    #expect(await useCase.activateFolderSearchMatch(document: document, match: match) == .stale(url.path))
    #expect(editor.revealedRange == nil)
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "new contents")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == false)
}

@Test @MainActor func saveAsBindsStableDocumentAndMarksItClean() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    _ = binding
    editor.replaceWith("저장🙂\r\n")
    let files = FileStoreFake()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let url = URL(fileURLWithPath: "/tmp/duckpad-save-as.txt")
    #expect(await useCase.saveAs(url) == .saved(workspace.snapshot().tabs[0].id))
    #expect(workspace.activeFileContext()?.binding?.canonicalPath == url.path)
    #expect(workspace.snapshot().tabs[0].title == url.lastPathComponent)
    #expect(workspace.snapshot().tabs[0].isDirty == false)
    #expect(await files.text(at: url) == "저장🙂\r\n")
}

@Test @MainActor func externalModificationRequiresExplicitResolutionAndDoesNotOverwrite() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-conflict.txt")
    await files.seed("original", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: url)
    guard case .conflict = await useCase.saveActive() else { Issue.record("expected conflict"); return }
    #expect(await files.text(at: url) == "external")
    guard case .ready(let comparison) = await useCase.pendingExternalComparison() else {
        Issue.record("comparison snapshot unavailable")
        return
    }
    #expect(comparison.tabID == workspace.activeFileContext()?.tabID)
    #expect(comparison.path == url.path)
    #expect(comparison.localText == "mine")
    #expect(comparison.externalText == "external")
    #expect(comparison.localRevision == workspace.activeFileContext()?.buffer.revision)
    #expect(await useCase.resolveConflict(.compare) == .conflict(
        tabID: comparison.tabID,
        current: comparison.externalIdentity
    ))
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "mine")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
    #expect(await files.text(at: url) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(workspace.activeFileContext()!.tabID))
    #expect(await files.text(at: url) == "external")
    guard case .conflict = await useCase.saveActive() else { Issue.record("expected second conflict"); return }
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "mine")
    #expect(await useCase.resolveConflict(.overwrite) == .saved(workspace.activeFileContext()!.tabID))
    #expect(await files.text(at: url) == "mine")
}

@Test @MainActor func independentWindowsDetectSameFileSaveConflicts() async {
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-multiwindow-conflict.txt")
    await files.seed("shared original", at: url)

    let firstWorkspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let firstEditor = FileEditorFake()
    let firstBinding = EditorBindingUseCase(workspace: firstWorkspace, editor: firstEditor)
    firstWorkspace.onChange = { firstBinding.render($0) }
    _ = firstBinding
    _ = await firstWorkspace.start()
    let firstFiles = FileDocumentUseCase(workspace: firstWorkspace, editor: firstEditor, store: files)

    let secondWorkspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let secondEditor = FileEditorFake()
    let secondBinding = EditorBindingUseCase(workspace: secondWorkspace, editor: secondEditor)
    secondWorkspace.onChange = { secondBinding.render($0) }
    _ = secondBinding
    _ = await secondWorkspace.start()
    let secondFiles = FileDocumentUseCase(workspace: secondWorkspace, editor: secondEditor, store: files)

    guard case .opened = await firstFiles.open(url),
          case .opened = await secondFiles.open(url) else {
        Issue.record("both independent windows must open the shared file")
        return
    }
    firstEditor.replaceWith("saved by first window")
    secondEditor.replaceWith("unsaved in second window")
    #expect(await firstFiles.saveActive() == .saved(firstWorkspace.activeFileContext()!.tabID))

    guard case .conflict = await secondFiles.saveActive() else {
        Issue.record("second window silently overwrote a newer file identity")
        return
    }
    #expect(await files.text(at: url) == "saved by first window")
    #expect(secondEditor.snapshot(for: secondWorkspace.activeFileContext()!.buffer.bufferID)?.text == "unsaved in second window")
    #expect(secondWorkspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
}

@Test @MainActor func oversizedExternalComparisonPreservesPendingConflict() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-large-conflict.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(
        workspace: workspace,
        editor: editor,
        store: files,
        maximumComparisonBytes: 4
    )
    _ = await useCase.open(url)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: url)

    guard case .conflict(let tabID, let current) = await useCase.saveActive() else {
        Issue.record("expected conflict")
        return
    }
    #expect(await useCase.pendingExternalComparison() == .failed(
        .comparisonTooLarge(actual: 8, limit: 4)
    ))
    #expect(await files.text(at: url) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(tabID))
    #expect(current != nil)
}

@Test @MainActor func editDuringExternalComparisonReadInvalidatesSnapshotWithoutConsumingConflict() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-comparison-edit-race.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine-before-read")
    await files.externalReplace("external", at: url)
    guard case .conflict(let tabID, _) = await useCase.saveActive() else {
        Issue.record("expected conflict")
        return
    }
    await files.armBlockedRead()

    let comparison = Task { await useCase.pendingExternalComparison() }
    await files.waitForBlockedRead()
    #expect(editor.replaceWith("mine-after-read") == .accepted(newRevision: 2))
    await files.releaseRead()

    #expect(await comparison.value == .failed(.comparisonInvalidated))
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "mine-after-read")
    #expect(await files.text(at: url) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(tabID))
}

@Test @MainActor func closeDuringExternalComparisonReadInvalidatesSnapshot() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-comparison-close-race.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: url)
    guard case .conflict(let tabID, _) = await useCase.saveActive() else {
        Issue.record("expected conflict")
        return
    }
    let revision = workspace.fileContext(tabID: tabID)!.buffer.revision
    await files.armBlockedRead()

    let comparison = Task { await useCase.pendingExternalComparison() }
    await files.waitForBlockedRead()
    guard case .closed = await workspace.close(tabID: tabID, decision: .discard, expectedRevision: revision) else {
        Issue.record("close failed")
        await files.releaseRead()
        return
    }
    await files.releaseRead()

    #expect(await comparison.value == .failed(.comparisonInvalidated))
    #expect(await files.text(at: url) == "external")
}

@Test @MainActor func editAfterPresentedComparisonPreventsReloadDataLoss() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-comparison-presented-edit.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine-before-compare")
    _ = await workspace.flushPersistence()
    await files.externalReplace("external", at: url)
    guard case .conflict(let tabID, _) = await useCase.saveActive(),
          case .ready = await useCase.pendingExternalComparison() else {
        Issue.record("comparison unavailable")
        return
    }

    #expect(editor.replaceWith("mine-after-compare") == .accepted(newRevision: 2))
    guard case .failed(.editorRevisionMismatch(_, let expected, let actual)) =
        await useCase.resolveConflict(.reload) else {
        Issue.record("reload did not reject the newer edit")
        return
    }
    #expect(expected == 1)
    #expect(actual == 2)
    #expect(editor.snapshot(for: workspace.fileContext(tabID: tabID)!.buffer.bufferID)?.text == "mine-after-compare")
    #expect(await files.text(at: url) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(tabID))
}

@Test @MainActor func editDuringReloadReadPreventsReloadDataLoss() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-reload-edit-race.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine-before-reload")
    _ = await workspace.flushPersistence()
    await files.externalReplace("external", at: url)
    guard case .conflict(let tabID, _) = await useCase.saveActive() else {
        Issue.record("expected conflict")
        return
    }
    await files.armBlockedRead()

    let reload = Task { await useCase.resolveConflict(.reload) }
    await files.waitForBlockedRead()
    #expect(editor.replaceWith("mine-during-reload") == .accepted(newRevision: 2))
    await files.releaseRead()

    #expect(await reload.value == .failed(.editorRevisionMismatch(
        bufferID: workspace.fileContext(tabID: tabID)!.buffer.bufferID,
        expected: 1,
        actual: 2
    )))
    #expect(editor.snapshot(for: workspace.fileContext(tabID: tabID)!.buffer.bufferID)?.text == "mine-during-reload")
    #expect(await files.text(at: url) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(tabID))
}

@Test @MainActor func closeAfterPresentedComparisonInvalidatesReload() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let url = URL(fileURLWithPath: "/tmp/duckpad-comparison-presented-close.txt")
    await files.seed("base", at: url)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(url)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: url)
    guard case .conflict(let tabID, _) = await useCase.saveActive(),
          case .ready = await useCase.pendingExternalComparison() else {
        Issue.record("comparison unavailable")
        return
    }
    let revision = workspace.fileContext(tabID: tabID)!.buffer.revision
    guard case .closed = await workspace.close(tabID: tabID, decision: .discard, expectedRevision: revision) else {
        Issue.record("close failed")
        return
    }

    #expect(await useCase.resolveConflict(.reload) == .failed(.comparisonInvalidated))
    #expect(await files.text(at: url) == "external")
}

@Test @MainActor func rebindAfterPresentedComparisonInvalidatesReloadAtSameRevision() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let originalURL = URL(fileURLWithPath: "/tmp/duckpad-comparison-original.txt")
    let reboundURL = URL(fileURLWithPath: "/tmp/duckpad-comparison-rebound.txt")
    await files.seed("base", at: originalURL)
    await files.seed("rebound", at: reboundURL)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(originalURL)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: originalURL)
    guard case .conflict(let tabID, _) = await useCase.saveActive(),
          case .ready = await useCase.pendingExternalComparison(),
          let reboundRead = await files.result(at: reboundURL),
          let context = workspace.fileContext(tabID: tabID) else {
        Issue.record("comparison fixture unavailable")
        return
    }
    let reboundBinding = FileBinding(
        canonicalPath: reboundRead.identity.canonicalPath,
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .none,
        observedIdentity: reboundRead.identity
    )
    guard case .applied = await workspace.bindSavedFile(
        tabID: tabID,
        binding: reboundBinding,
        title: reboundURL.lastPathComponent,
        savedRevision: context.buffer.revision
    ) else {
        Issue.record("rebind failed")
        return
    }

    #expect(workspace.fileContext(tabID: tabID)?.buffer.revision == context.buffer.revision)
    #expect(await useCase.resolveConflict(.reload) == .failed(.comparisonInvalidated))
    #expect(workspace.fileContext(tabID: tabID)?.binding == reboundBinding)
    #expect(editor.snapshot(for: context.buffer.bufferID)?.text == "mine")
    #expect(await files.text(at: originalURL) == "external")
    #expect(await useCase.resolveConflict(.cancel) == .cancelled(tabID))
}

@Test @MainActor func rebindBeforeConflictOverwritePreservesNewAuthorityAndOldBytes() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let originalURL = URL(fileURLWithPath: "/tmp/duckpad-overwrite-original.txt")
    let reboundURL = URL(fileURLWithPath: "/tmp/duckpad-overwrite-rebound.txt")
    await files.seed("base", at: originalURL)
    await files.seed("rebound", at: reboundURL)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(originalURL)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: originalURL)
    guard case .conflict(let tabID, _) = await useCase.saveActive(),
          let reboundRead = await files.result(at: reboundURL),
          let context = workspace.fileContext(tabID: tabID) else {
        Issue.record("conflict fixture unavailable")
        return
    }
    let reboundBinding = FileBinding(
        canonicalPath: reboundRead.identity.canonicalPath,
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .none,
        observedIdentity: reboundRead.identity
    )
    guard case .applied = await workspace.bindSavedFile(
        tabID: tabID,
        binding: reboundBinding,
        title: reboundURL.lastPathComponent,
        savedRevision: context.buffer.revision
    ) else {
        Issue.record("rebind failed")
        return
    }

    #expect(await useCase.resolveConflict(.overwrite) == .failed(.comparisonInvalidated))
    #expect(workspace.fileContext(tabID: tabID)?.binding == reboundBinding)
    #expect(await files.text(at: originalURL) == "external")
    #expect(await files.text(at: reboundURL) == "rebound")
}

@Test @MainActor func rebindDuringConflictOverwriteWriteCannotClobberNewBinding() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = binding
    _ = await workspace.start()
    let files = FileStoreFake()
    let originalURL = URL(fileURLWithPath: "/tmp/duckpad-overwrite-race-original.txt")
    let reboundURL = URL(fileURLWithPath: "/tmp/duckpad-overwrite-race-rebound.txt")
    await files.seed("base", at: originalURL)
    await files.seed("rebound", at: reboundURL)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    _ = await useCase.open(originalURL)
    editor.replaceWith("mine")
    await files.externalReplace("external", at: originalURL)
    guard case .conflict(let tabID, _) = await useCase.saveActive(),
          let reboundRead = await files.result(at: reboundURL),
          let context = workspace.fileContext(tabID: tabID) else {
        Issue.record("conflict fixture unavailable")
        return
    }
    let reboundBinding = FileBinding(
        canonicalPath: reboundRead.identity.canonicalPath,
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .none,
        observedIdentity: reboundRead.identity
    )
    await files.armBlockedWrite()
    let overwrite = Task { await useCase.resolveConflict(.overwrite) }
    await files.waitForBlockedWrite()
    guard case .applied = await workspace.bindSavedFile(
        tabID: tabID,
        binding: reboundBinding,
        title: reboundURL.lastPathComponent,
        savedRevision: context.buffer.revision
    ) else {
        Issue.record("rebind failed")
        await files.releaseWrite()
        return
    }
    await files.releaseWrite()

    #expect(await overwrite.value == .failed(.comparisonInvalidated))
    #expect(workspace.fileContext(tabID: tabID)?.binding == reboundBinding)
    #expect(await files.text(at: originalURL) == "mine")
    #expect(await files.text(at: reboundURL) == "rebound")
}

@Test @MainActor func editAcceptedDuringSaveRemainsDirtyAfterOlderSnapshotBecomesDurable() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("snapshot")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    await files.armBlockedWrite()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let url = URL(fileURLWithPath: "/tmp/duckpad-save-race.txt")
    let save = Task { await useCase.saveAs(url) }
    await files.waitForBlockedWrite()
    #expect(editor.replaceWith("newer edit") == .accepted(newRevision: 2))
    await files.releaseWrite()
    guard case .saved = await save.value else { Issue.record("save failed"); return }
    #expect(await files.text(at: url) == "snapshot")
    #expect(workspace.snapshot().tabs[0].isDirty)
    #expect(editor.snapshot(for: workspace.activeFileContext()!.buffer.bufferID)?.text == "newer edit")
}

@Test @MainActor func queuedFormatSaveRejectsActiveTabChangeBeforeOperationAdmission() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("first")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    await files.armBlockedWrite()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let firstURL = URL(fileURLWithPath: "/tmp/duckpad-queued-first.txt")
    let rejectedURL = URL(fileURLWithPath: "/tmp/duckpad-queued-rejected.txt")
    let originalContext = workspace.activeFileContext()!
    let firstSave = Task {
        await useCase.saveAs(firstURL, expectedContext: originalContext)
    }
    await files.waitForBlockedWrite()

    _ = await workspace.addScratch()
    let conversion = TextFileConversion(
        encoding: .utf16BigEndian,
        byteOrderMark: .absent,
        lineEnding: .crlf
    )
    let queuedSave = Task {
        await useCase.saveAs(
            rejectedURL,
            conversion: conversion,
            expectedContext: originalContext
        )
    }
    await Task.yield()
    await files.releaseWrite()

    #expect(await firstSave.value == .saved(originalContext.tabID))
    #expect(await queuedSave.value == .failed(.comparisonInvalidated))
    #expect(await files.data(at: rejectedURL) == nil)
    #expect(workspace.activeFileContext()?.tabID != originalContext.tabID)
}

@Test @MainActor func explicitFormatConversionPersistsAcrossFollowingOrdinarySave() async throws {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("한\n🙂")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let url = URL(fileURLWithPath: "/tmp/duckpad-conversion.txt")
    let conversion = TextFileConversion(encoding: .utf16LittleEndian, byteOrderMark: .absent, lineEnding: .crlf)
    guard case .saved = await useCase.saveAs(url, conversion: conversion) else { Issue.record("conversion save failed"); return }
    var decoded = try TextFileCodec.decode(await files.data(at: url)!, assuming: .utf16LittleEndian)
    #expect(decoded.text == "한\r\n🙂")
    #expect(workspace.activeFileContext()?.binding?.lineEnding == .crlf)

    editor.replaceWith("한\n🙂\n다음")
    _ = await workspace.flushPersistence()
    guard case .saved = await useCase.saveActive() else { Issue.record("ordinary save failed"); return }
    decoded = try TextFileCodec.decode(await files.data(at: url)!, assuming: .utf16LittleEndian)
    #expect(decoded.text == "한\r\n🙂\r\n다음")
    #expect(decoded.byteOrderMark == .absent)
}

@Test @MainActor func saveCopyWritesCurrentSnapshotWithoutRebindingOrCleaningDocument() async throws {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("한\ncopy 🙂")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let destination = URL(fileURLWithPath: "/tmp/duckpad-copy.txt")
    let before = try #require(workspace.activeFileContext())

    let outcome = await useCase.saveCopy(
        destination,
        conversion: TextFileConversion(
            encoding: .utf16LittleEndian,
            byteOrderMark: .present,
            lineEnding: .crlf
        ),
        expectedContext: before
    )

    #expect(outcome == .saved(before.tabID))
    #expect(workspace.activeFileContext() == before)
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
    let copied = try #require(await files.data(at: destination))
    let decoded = try TextFileCodec.decode(copied)
    #expect(decoded.text == "한\r\ncopy 🙂")
    #expect(decoded.encoding == .utf16LittleEndian)
    #expect(decoded.byteOrderMark == .present)
}

@Test @MainActor func saveCopyDetectsDestinationReplacementAndPreservesExternalBytes() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("copy candidate")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    let destination = URL(fileURLWithPath: "/tmp/duckpad-copy-race.txt")
    await files.seed("consented destination", at: destination)
    await files.armBlockedWrite()
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let save = Task { await useCase.saveCopy(destination) }
    await files.waitForBlockedWrite()

    await files.externalReplace("external replacement", at: destination)
    await files.releaseWrite()

    guard case .failed(.store(.conflict)) = await save.value else {
        Issue.record("destination replacement was not reported as a conflict")
        return
    }
    #expect(await files.text(at: destination) == "external replacement")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
    #expect(workspace.activeFileContext()?.binding == nil)
}

@Test @MainActor func durabilityFailureDoesNotBindOrCleanLiveDocument() async {
    let workspace = ScratchWorkspaceUseCase(store: FileSessionStoreFake())
    let editor = FileEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    workspace.onChange = { binding.render($0) }
    _ = await workspace.start()
    editor.display(workspace.snapshot().activeBuffer!)
    editor.replaceWith("must remain dirty")
    _ = await workspace.flushPersistence()
    let files = FileStoreFake()
    await files.setWriteError(.durabilityFailure(
        state: .replacementVisibleDurabilityUncertain,
        current: nil,
        recoveryPath: "/tmp/recovery",
        detail: "injected"
    ))
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let outcome = await useCase.saveAs(URL(fileURLWithPath: "/tmp/duckpad-durability.txt"))
    guard case .failed(.store(.durabilityFailure(let state, _, _, _))) = outcome else {
        Issue.record("expected typed durability failure, got \(outcome)")
        return
    }
    #expect(state == .replacementVisibleDurabilityUncertain)
    #expect(workspace.activeFileContext()?.binding == nil)
    #expect(workspace.snapshot().tabs[0].isDirty)
    #expect(editor.snapshot(for: workspace.snapshot().tabs[0].buffer.bufferID)?.text == "must remain dirty")
}

private actor FileSessionStoreFake: SessionStore {
    private var stored: StoredSession?
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if let stored, stored.generation >= generation { return .superseded(durableGeneration: stored.generation) }
        stored = StoredSession(session: session, generation: generation)
        return .committed
    }
}
