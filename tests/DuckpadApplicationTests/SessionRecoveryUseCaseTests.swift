import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

private actor RecoveryMetadataStore: SessionStore {
    private var stored: StoredSession?
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if let stored, stored.generation >= generation { return .superseded(durableGeneration: stored.generation) }
        stored = StoredSession(session: session, generation: generation)
        return .committed
    }
}

private actor RecoveryStoreFake: RecoveryStore {
    private var stored: StoredRecoveryArchive?
    private var failure: SessionStoreError?
    private var blockNextCommit = false
    private var commitEntered = false
    private var releaseCommit = false
    private(set) var commitCount = 0

    init(stored: StoredRecoveryArchive? = nil) { self.stored = stored }

    func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? { stored }

    func commit(_ archive: RecoveryArchive, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if blockNextCommit {
            blockNextCommit = false
            commitEntered = true
            while !releaseCommit { await Task.yield() }
        }
        if let failure { throw failure }
        if let stored, stored.generation >= generation {
            return .superseded(durableGeneration: stored.generation)
        }
        stored = StoredRecoveryArchive(archive: archive, generation: generation)
        commitCount += 1
        return .committed
    }

    func reset() async throws(SessionStoreError) { stored = nil }
    func setFailure(_ failure: SessionStoreError?) { self.failure = failure }
    func armBlockedCommit() { blockNextCommit = true; commitEntered = false; releaseCommit = false }
    func waitUntilCommitEntered() async { while !commitEntered { await Task.yield() } }
    func releaseBlockedCommit() { releaseCommit = true }
    func latest() -> StoredRecoveryArchive? { stored }
}

@MainActor
private final class RecoveryEditorFake: EditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    private(set) var active: EditorBufferDescriptor?
    private(set) var inputEnabled = true
    private var values: [BufferID: EditorRecoverySnapshot] = [:]

    func display(_ buffer: EditorBufferDescriptor) {
        active = buffer
        if values[buffer.bufferID] == nil {
            values[buffer.bufferID] = EditorRecoverySnapshot(bufferID: buffer.bufferID, revision: buffer.revision, utf8: Data())
        }
    }
    func install(_ snapshot: EditorTextSnapshot) {
        values[snapshot.bufferID] = EditorRecoverySnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, utf8: Data(snapshot.text.utf8))
    }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        guard let value = values[bufferID], let text = String(data: value.utf8, encoding: .utf8) else { return nil }
        return EditorTextSnapshot(bufferID: bufferID, revision: value.revision, text: text)
    }
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { values[bufferID] }
    func installRecovery(_ snapshot: EditorRecoverySnapshot) { values[snapshot.bufferID] = snapshot }
    func retire(bufferID: BufferID) { values.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) { inputEnabled = isEnabled }
    func focus() {}

    func insert(_ text: String) -> EditorEditOutcome? {
        guard inputEnabled, let active, var value = values[active.bufferID] else { return nil }
        let edit = EditorIncrementalEdit(
            bufferID: active.bufferID,
            expectedRevision: active.revision,
            range: TextEditRange(location: value.utf8.count, length: 0),
            replacement: text
        )
        let outcome = onEdit?(edit)
        if case .accepted(let revision) = outcome {
            value = EditorRecoverySnapshot(
                bufferID: active.bufferID,
                revision: revision,
                utf8: value.utf8 + Data(text.utf8),
                viewState: value.viewState
            )
            values[active.bufferID] = value
            self.active = EditorBufferDescriptor(bufferID: active.bufferID, revision: revision)
        }
        return outcome
    }
}

@MainActor
private func recoveryHarness(
    store: RecoveryStoreFake
) -> (ScratchWorkspaceUseCase, RecoveryEditorFake, EditorBindingUseCase, SessionRecoveryUseCase) {
    let workspace = ScratchWorkspaceUseCase(store: RecoveryMetadataStore())
    let editor = RecoveryEditorFake()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    let recovery = SessionRecoveryUseCase(workspace: workspace, editor: editor, store: store, debounce: .milliseconds(20))
    workspace.onChange = { change in
        binding.render(change)
        recovery.workspaceDidChange(change)
    }
    binding.render(workspace.snapshot())
    return (workspace, editor, binding, recovery)
}

private func recoveredFileBinding() -> FileBinding {
    let identity = FileIdentity(
        canonicalPath: "/tmp/dirty-recovered.txt",
        device: 7,
        inode: 8,
        byteCount: 9,
        modifiedNanoseconds: 10,
        contentToken: "external-conflict-token"
    )
    return FileBinding(
        canonicalPath: identity.canonicalPath,
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .lf,
        observedIdentity: identity
    )
}

@Test func legacyEditorViewStateDefaultsWrapMarkerToHidden() throws {
    let legacy = Data(#"{"anchorUTF8":1,"caretUTF8":2,"firstVisibleLine":3,"horizontalScrollOffset":4,"wordWrapEnabled":false}"#.utf8)
    let decoded = try JSONDecoder().decode(EditorViewState.self, from: legacy)
    #expect(decoded.anchorUTF8 == 1)
    #expect(!decoded.wordWrapEnabled)
    #expect(!decoded.wrapMarkerVisible)
    #expect(decoded.bookmarkedLines.isEmpty)

    let roundTrip = try JSONDecoder().decode(
        EditorViewState.self,
        from: JSONEncoder().encode(EditorViewState(wrapMarkerVisible: true, bookmarkedLines: [4, 1, 4]))
    )
    #expect(roundTrip.wrapMarkerVisible)
    #expect(roundTrip.bookmarkedLines == [1, 4])

    let bounded = EditorViewState(bookmarkedLines: Array(0...EditorViewState.maximumBookmarkCount))
    #expect(bounded.bookmarkedLines.count == EditorViewState.maximumBookmarkCount)
    #expect(bounded.bookmarkedLines.last == EditorViewState.maximumBookmarkCount - 1)

    let negative = Data(#"{"anchorUTF8":0,"caretUTF8":0,"firstVisibleLine":0,"horizontalScrollOffset":0,"wordWrapEnabled":true,"bookmarkedLines":[-1]}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(EditorViewState.self, from: negative)
    }
}

@Test @MainActor func startupRestoresTabOrderActiveDirtyFileTextAndViewStateBeforeEditing() async throws {
    var session = ScratchSession()
    let firstBuffer = BufferMetadata(revision: 2, isDirty: true)
    let firstTab = try session.addUntitled(buffer: firstBuffer)
    let secondTab = try session.addFile(binding: recoveredFileBinding(), title: "dirty-recovered.txt")
    _ = try session.recordEdit(in: secondTab, expectedRevision: 0)
    try session.activate(tabID: firstTab)
    let secondBuffer = try session.buffer(for: secondTab)
    let firstState = EditorViewState(anchorUTF8: 1, caretUTF8: 4, firstVisibleLine: 8, horizontalScrollOffset: 3, wordWrapEnabled: false)
    let archive = RecoveryArchive(session: session, buffers: [
        firstBuffer.id: EditorRecoverySnapshot(bufferID: firstBuffer.id, revision: 2, utf8: Data("untitled🙂".utf8), viewState: firstState),
        secondBuffer.id: EditorRecoverySnapshot(bufferID: secondBuffer.id, revision: 1, utf8: Data("dirty file 한글".utf8)),
    ])
    let store = RecoveryStoreFake(stored: StoredRecoveryArchive(archive: archive, generation: PersistenceGeneration(rawValue: 4)))
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)

    #expect(await recovery.start() == .saved)
    #expect(workspace.snapshot().tabs.map(\.id) == [firstTab, secondTab])
    #expect(workspace.snapshot().tabs.first?.isActive == true)
    #expect(workspace.snapshot().tabs.allSatisfy { $0.isDirty })
    #expect(editor.recoverySnapshot(for: firstBuffer.id)?.utf8 == Data("untitled🙂".utf8))
    #expect(editor.recoverySnapshot(for: firstBuffer.id)?.viewState == firstState)
    #expect(workspace.fileContext(tabID: secondTab)?.binding?.observedIdentity.contentToken == "external-conflict-token")
    #expect(editor.inputEnabled)
}

@Test @MainActor func untitledAutosaveRelaunchRestoresAcceptedTextWithoutPrompt() async throws {
    let store = RecoveryStoreFake()
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)
    #expect(await recovery.start() == .saved)
    #expect(editor.insert("scratch 한글🙂") == .accepted(newRevision: 1))
    await recovery.waitForPendingAutosave()
    let originalTab = workspace.snapshot().tabs[0].id

    let (relaunched, relaunchedEditor, _, secondRecovery) = recoveryHarness(store: store)
    #expect(await secondRecovery.start() == .saved)
    #expect(relaunched.snapshot().tabs[0].id == originalTab)
    #expect(relaunchedEditor.recoverySnapshot(for: relaunched.snapshot().activeBuffer!.bufferID)?.utf8 == Data("scratch 한글🙂".utf8))
    #expect(relaunched.snapshot().tabs[0].isDirty)
}

@Test @MainActor func editDuringBlockedSnapshotCommitSchedulesFollowUpAndRemainsDirty() async throws {
    let store = RecoveryStoreFake()
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    #expect(editor.insert("A") == .accepted(newRevision: 1))
    await workspace.waitForPendingPersistence()
    await store.armBlockedCommit()
    let firstFlush = Task { await recovery.flush() }
    await store.waitUntilCommitEntered()
    #expect(editor.insert("B") == .accepted(newRevision: 2))
    await store.releaseBlockedCommit()
    _ = await firstFlush.value
    await recovery.waitForPendingAutosave()

    let latest = try #require(await store.latest())
    #expect(latest.archive.buffers.values.first?.utf8 == Data("AB".utf8))
    #expect(latest.archive.buffers.values.first?.revision == 2)
    #expect(workspace.snapshot().tabs[0].isDirty)
}

@Test @MainActor func terminationFlushWaitsForOlderWriteAndPersistsNewestAcceptedEdit() async throws {
    let store = RecoveryStoreFake()
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    await recovery.waitForPendingAutosave()
    #expect(editor.insert("A") == .accepted(newRevision: 1))
    await workspace.waitForPendingPersistence()

    await store.armBlockedCommit()
    let olderFlush = Task { await recovery.flush() }
    await store.waitUntilCommitEntered()
    #expect(editor.insert("B") == .accepted(newRevision: 2))

    let finalFlush = Task { await recovery.flushForTermination() }
    await Task.yield()
    #expect(!editor.inputEnabled)
    #expect(editor.insert("must be gated") == nil)
    await store.releaseBlockedCommit()
    guard case .saved = await olderFlush.value else {
        Issue.record("older queued flush should complete before final flush")
        return
    }
    guard case .saved = await finalFlush.value else {
        Issue.record("final flush must save the newest state")
        return
    }

    let latest = try #require(await store.latest())
    #expect(latest.archive.buffers.values.first?.utf8 == Data("AB".utf8))
    #expect(latest.archive.buffers.values.first?.revision == 2)
    #expect(editor.inputEnabled)
}

@Test @MainActor func discardIsNotAppliedUntilRecoveryManifestCommitSucceeds() async throws {
    let store = RecoveryStoreFake()
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    #expect(editor.insert("do not resurrect") == .accepted(newRevision: 1))
    _ = await recovery.flush()
    let original = workspace.snapshot().tabs[0]
    await store.setFailure(.unavailable("disk full"))

    guard case .persistenceFailed = await workspace.close(tabID: original.id, decision: .discard) else {
        Issue.record("discard must fail closed when recovery commit fails")
        return
    }
    #expect(workspace.snapshot().tabs[0].id == original.id)
    #expect(workspace.snapshot().tabs[0].isDirty)

    await store.setFailure(nil)
    guard case .closed = await workspace.close(tabID: original.id, decision: .discard) else {
        Issue.record("discard should apply after durable recovery commit")
        return
    }
    let latest = try #require(await store.latest())
    #expect(latest.archive.session.tabs.count == 1)
    #expect(latest.archive.session.tabs[0].id != original.id)
    #expect(latest.archive.buffers[original.buffer.bufferID] == nil)
}

@Test @MainActor func undoClosePublishesOnlyAfterRecoveredBytesAreDurable() async throws {
    let store = RecoveryStoreFake()
    let (workspace, editor, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    #expect(editor.insert("durable recently closed 🦆") == .accepted(newRevision: 1))
    _ = await recovery.flush()
    let original = workspace.snapshot().tabs[0]
    _ = await workspace.addScratch()

    guard case .closed = await workspace.close(
        tabID: original.id,
        decision: .discard,
        expectedRevision: 1
    ) else {
        Issue.record("dirty close should commit")
        return
    }
    #expect((await store.latest())?.archive.buffers[original.buffer.bufferID] == nil)

    #expect(await workspace.restoreLastClosedTab() == .applied(.saved))
    let latest = try #require(await store.latest())
    #expect(latest.archive.session.tabs.contains(where: { $0.id == original.id }))
    #expect(latest.archive.buffers[original.buffer.bufferID]?.revision == 1)
    #expect(latest.archive.buffers[original.buffer.bufferID]?.utf8 == Data("durable recently closed 🦆".utf8))
    #expect(workspace.snapshot().tabs.first(where: { $0.id == original.id })?.isActive == true)
}

@Test @MainActor func rapidRecoveryEditsCoalesceToOneAdditionalArchiveCommit() async {
    let store = RecoveryStoreFake()
    let (_, editor, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    await recovery.waitForPendingAutosave()
    let before = await store.commitCount
    for value in ["a", "b", "c"] { _ = editor.insert(value) }
    await recovery.waitForPendingAutosave()
    #expect(await store.commitCount == before + 1)
}

@Test @MainActor func editorViewOptionChangeSchedulesRecoveryWithoutDocumentEdit() async {
    let store = RecoveryStoreFake()
    let (_, _, _, recovery) = recoveryHarness(store: store)
    _ = await recovery.start()
    await recovery.waitForPendingAutosave()
    let before = await store.commitCount

    recovery.editorViewStateDidChange()
    await recovery.waitForPendingAutosave()

    #expect(await store.commitCount == before + 1)
}
