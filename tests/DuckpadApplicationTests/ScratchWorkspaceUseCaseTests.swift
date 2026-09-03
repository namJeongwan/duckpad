import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

private actor StoreSpy: SessionStore {
    private var session: ScratchSession?
    private var failure: SessionStoreError?
    private(set) var saveCount = 0
    private var durableGeneration = PersistenceGeneration(rawValue: 0)

    init(session: ScratchSession? = nil, failure: SessionStoreError? = nil) {
        self.session = session
        self.failure = failure
    }

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        if let failure { throw failure }
        return session.map { StoredSession(session: $0, generation: durableGeneration) }
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        if let failure { throw failure }
        guard generation > durableGeneration else {
            return .superseded(durableGeneration: durableGeneration)
        }
        self.session = session
        durableGeneration = generation
        saveCount += 1
        return .committed
    }

    func storedSession() -> ScratchSession? { session }
    func setFailure(_ failure: SessionStoreError?) { self.failure = failure }
}

private actor DelayedLoadStore: SessionStore {
    private var session: ScratchSession?
    private var blocked = true
    private var loadEntered = false
    private var durableGeneration = PersistenceGeneration(rawValue: 0)

    init(session: ScratchSession?) { self.session = session }

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        loadEntered = true
        while blocked { await Task.yield() }
        return session.map { StoredSession(session: $0, generation: durableGeneration) }
    }

    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        guard generation > durableGeneration else { return .superseded(durableGeneration: durableGeneration) }
        self.session = session
        durableGeneration = generation
        return .committed
    }

    func waitUntilLoadEntered() async {
        while !loadEntered { await Task.yield() }
    }

    func releaseLoad() { blocked = false }
}

private actor AdversarialStore: SessionStore {
    private var session: ScratchSession?
    private var durableGeneration = PersistenceGeneration(rawValue: 0)
    private var shouldBlockNextCommit = false
    private var blockedCommitEntered = false
    private var releaseBlockedCommit = false
    private var concurrentCommits = 0
    private(set) var maximumConcurrentCommits = 0

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: durableGeneration) }
    }

    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        concurrentCommits += 1
        maximumConcurrentCommits = max(maximumConcurrentCommits, concurrentCommits)
        if shouldBlockNextCommit {
            shouldBlockNextCommit = false
            blockedCommitEntered = true
            while !releaseBlockedCommit { await Task.yield() }
        }
        defer { concurrentCommits -= 1 }
        guard generation > durableGeneration else { return .superseded(durableGeneration: durableGeneration) }
        self.session = session
        durableGeneration = generation
        return .committed
    }

    func armBlockingCommit() {
        shouldBlockNextCommit = true
        releaseBlockedCommit = false
        blockedCommitEntered = false
    }

    func waitUntilCommitEntered() async {
        while !blockedCommitEntered { await Task.yield() }
    }

    func releaseCommit() { releaseBlockedCommit = true }
    func storedRevision(for id: BufferID) -> UInt64? { session?.buffers[id]?.revision }
    func storedTabCount() -> Int { session?.tabs.count ?? 0 }
}

@MainActor
private final class EditorFake: EditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    private(set) var displayed: EditorBufferDescriptor?
    private(set) var inputEnabled = true
    private(set) var retired: [BufferID] = []
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var viewStates: [BufferID: EditorViewState] = [:]

    func display(_ buffer: EditorBufferDescriptor) {
        displayed = buffer
        if let old = snapshots[buffer.bufferID] {
            snapshots[buffer.bufferID] = EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: old.text)
        } else {
            snapshots[buffer.bufferID] = EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
        }
    }
    func install(_ snapshot: EditorTextSnapshot) {
        snapshots[snapshot.bufferID] = snapshot
        viewStates[snapshot.bufferID] = viewStates[snapshot.bufferID] ?? EditorViewState()
        if displayed?.bufferID == snapshot.bufferID {
            displayed = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision)
        }
    }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        snapshots[bufferID]
    }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        guard let snapshot = snapshots[bufferID] else { return nil }
        return EditorRecoveryCapture(
            bufferID: bufferID,
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: Data(snapshot.text.utf8),
            viewState: viewStates[bufferID] ?? EditorViewState()
        )
    }
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {
        viewStates[snapshot.bufferID] = snapshot.viewState
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { return }
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
    }
    func focus() {}
    func retire(bufferID: BufferID) {
        retired.append(bufferID)
        snapshots.removeValue(forKey: bufferID)
        viewStates.removeValue(forKey: bufferID)
        if displayed?.bufferID == bufferID { displayed = nil }
    }
    func setInputEnabled(_ isEnabled: Bool) { inputEnabled = isEnabled }

    func setViewState(_ state: EditorViewState, for bufferID: BufferID) {
        viewStates[bufferID] = state
    }

    func insert(_ replacement: String) -> EditorEditOutcome? {
        guard inputEnabled, let displayed, let current = snapshots[displayed.bufferID] else { return nil }
        let outcome = onEdit?(
            EditorIncrementalEdit(
                bufferID: displayed.bufferID,
                expectedRevision: displayed.revision,
                range: TextEditRange(location: current.text.utf16.count, length: 0),
                replacement: replacement
            )
        )
        if case .accepted(let revision) = outcome {
            snapshots[displayed.bufferID] = EditorTextSnapshot(
                bufferID: displayed.bufferID,
                revision: revision,
                text: current.text + replacement
            )
            self.displayed = EditorBufferDescriptor(
                bufferID: displayed.bufferID,
                revision: revision
            )
        }
        return outcome
    }
}

@Test @MainActor func startsRestoringThenBecomesEditableAndPersistsOnce() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    var received: [WorkspaceChange] = []
    useCase.onChange = { received.append($0) }
    #expect(useCase.snapshot().tabs.count == 1)
    #expect(useCase.snapshot().activeBuffer != nil)
    #expect(await useCase.start() == .saved)
    #expect(received.first?.snapshot.startup == .restoring)
    #expect(received.last?.snapshot.startup == .ready)
    #expect(await store.saveCount == 1)
    #expect(await store.storedSession()?.tabs.count == 1)
}

@Test @MainActor func finalTabCloseCreatesReplacementThenPersistsAndPublishesOnce() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let oldTab = useCase.snapshot().tabs[0].id
    let saveCountBeforeClose = await store.saveCount
    var published: [WorkspaceChange] = []
    useCase.onChange = { published.append($0) }

    let outcome = await useCase.close(tabID: oldTab)

    guard case .closed(let active, let replacementCreated, .saved) = outcome else {
        Issue.record("expected successful replacement close, got \(outcome)")
        return
    }
    #expect(replacementCreated)
    #expect(active != oldTab)
    #expect(useCase.snapshot().tabs.map(\.id) == [active])
    #expect(await store.storedSession()?.tabs.map(\.id) == [active])
    #expect(await store.saveCount == saveCountBeforeClose + 1)
    #expect(published.count == 1)
    #expect(published[0].snapshot.tabs.map(\.id) == [active])
}

@Test @MainActor func dirtyCloseRequiresExplicitDiscardAndCancelRetainsLiveReference() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let tab = useCase.snapshot().tabs[0]
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: tab.buffer.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "unsaved"
    )) == .accepted(newRevision: 1))

    #expect(await useCase.close(tabID: tab.id) == .requiresDecision(saveAvailable: false))
    #expect(await useCase.close(tabID: tab.id, decision: .cancel) == .cancelled)
    #expect(await useCase.close(tabID: tab.id, decision: .save) == .saveUnavailable)
    #expect(useCase.snapshot().tabs.map(\.id) == [tab.id])

    let discarded = await useCase.close(tabID: tab.id, decision: .discard)
    guard case .closed(let active, true, .saved) = discarded else {
        Issue.record("explicit discard should close and replace")
        return
    }
    #expect(active != tab.id)
    #expect(useCase.snapshot().tabs.map(\.id) == [active])
}

@Test @MainActor func undoCloseRestoresDirtyEditorBytesAndStableTabIdentity() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }

    let original = useCase.snapshot().tabs[0]
    #expect(editor.insert("recover me 🦆") == .accepted(newRevision: 1))
    _ = await useCase.flushPersistence()
    _ = await useCase.addScratch()

    guard case .closed = await useCase.close(
        tabID: original.id,
        decision: .discard,
        expectedRevision: 1
    ) else {
        Issue.record("dirty close should succeed")
        return
    }
    #expect(useCase.canRestoreRecentlyClosedTab)
    #expect(useCase.recentlyClosedTabCount == 1)
    #expect(editor.snapshot(for: original.buffer.bufferID) == nil)

    #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    let restored = try! #require(useCase.snapshot().tabs.first(where: { $0.id == original.id }))
    #expect(restored.isActive)
    #expect(restored.isDirty)
    #expect(restored.buffer.revision == 1)
    #expect(editor.snapshot(for: original.buffer.bufferID)?.text == "recover me 🦆")
    #expect(!useCase.canRestoreRecentlyClosedTab)
    #expect(useCase.recentlyClosedTabCount == 0)
}

@Test @MainActor func undoCloseReplacesOnlyUntouchedAutomaticScratch() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }

    let original = useCase.snapshot().tabs[0]
    guard case .closed(_, true, .saved) = await useCase.close(tabID: original.id) else {
        Issue.record("final close should create a replacement")
        return
    }
    let untouchedReplacement = useCase.snapshot().tabs[0]
    #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    #expect(useCase.snapshot().tabs.map(\.id) == [original.id])
    #expect(editor.retired == [original.buffer.bufferID, untouchedReplacement.buffer.bufferID])

    guard case .closed(_, true, .saved) = await useCase.close(tabID: original.id) else {
        Issue.record("second final close should create a replacement")
        return
    }
    let editedReplacement = useCase.snapshot().tabs[0]
    #expect(editor.insert("keep this") == .accepted(newRevision: 1))
    #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    #expect(useCase.snapshot().tabs.map(\.id) == [original.id, editedReplacement.id])
    #expect(editor.snapshot(for: editedReplacement.buffer.bufferID)?.text == "keep this")
}

@Test @MainActor func undoClosePreservesPinnedLanguageOrViewCustomizedReplacement() async {
    for customization in 0..<3 {
        let store = StoreSpy()
        let useCase = ScratchWorkspaceUseCase(store: store)
        _ = await useCase.start()
        let editor = EditorFake()
        let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
        binding.render(useCase.snapshot())
        useCase.onChange = { binding.render($0) }
        let original = useCase.snapshot().tabs[0]
        _ = await useCase.close(tabID: original.id)
        let replacement = useCase.snapshot().tabs[0]

        switch customization {
        case 0:
            _ = await useCase.setPinned(replacement.id, isPinned: true)
        case 1:
            _ = await useCase.setLanguageOverride(
                .manual(LanguageID(rawValue: "swift")),
                for: replacement.id
            )
        default:
            editor.setViewState(
                EditorViewState(wordWrapEnabled: false, wrapMarkerVisible: true),
                for: replacement.buffer.bufferID
            )
        }

        #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
        #expect(useCase.snapshot().tabs.count == 2)
        #expect(useCase.snapshot().tabs.contains(where: { $0.id == replacement.id }))
        if customization == 0 {
            #expect(useCase.snapshot().tabs.first(where: { $0.id == replacement.id })?.isPinned == true)
        } else if customization == 1 {
            #expect((try? useCase.recoverySession().languageOverride(for: replacement.id)) == .manual(LanguageID(rawValue: "swift")))
        } else {
            #expect(editor.recoveryCapture(for: replacement.buffer.bufferID)?.viewState.wordWrapEnabled == false)
            #expect(editor.recoveryCapture(for: replacement.buffer.bufferID)?.viewState.wrapMarkerVisible == true)
        }
    }
}

@Test @MainActor func failedUndoCloseKeepsStackAndRetriesWithoutLeakingInstalledBuffer() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    var retry: PersistenceRetry?
    useCase.onChange = { change in
        binding.render(change)
        retry = change.failureEvent?.retry ?? retry
    }
    let original = useCase.snapshot().tabs[0]
    _ = await useCase.addScratch()
    _ = await useCase.close(tabID: original.id)

    await store.setFailure(.unavailable("restore blocked"))
    guard case .persistenceFailed = await useCase.restoreLastClosedTab() else {
        Issue.record("restore should expose persistence failure")
        return
    }
    #expect(useCase.recentlyClosedTabCount == 1)
    #expect(editor.snapshot(for: original.buffer.bufferID) == nil)

    await store.setFailure(nil)
    guard let retry else {
        Issue.record("restore failure should publish a typed retry")
        return
    }
    #expect(await useCase.retry(retry) == .saved)
    #expect(useCase.snapshot().tabs.contains(where: { $0.id == original.id }))
    #expect(useCase.recentlyClosedTabCount == 0)
    #expect(editor.snapshot(for: original.buffer.bufferID) != nil)
}

@Test @MainActor func staleRestoreRetryCannotConsumeNextRecentlyClosedEntry() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    var failedRetry: PersistenceRetry?
    useCase.onChange = { change in
        binding.render(change)
        failedRetry = change.failureEvent?.retry ?? failedRetry
    }
    let older = useCase.snapshot().tabs[0]
    _ = await useCase.addScratch()
    let newest = useCase.snapshot().tabs[1]
    _ = await useCase.addScratch()
    _ = await useCase.close(tabID: older.id)
    _ = await useCase.close(tabID: newest.id)

    await store.setFailure(.unavailable("restore blocked"))
    guard case .persistenceFailed = await useCase.restoreLastClosedTab() else {
        Issue.record("newest restore should fail")
        return
    }
    let retry = try! #require(failedRetry)
    await store.setFailure(nil)
    #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    #expect(useCase.snapshot().tabs.contains(where: { $0.id == newest.id }))
    #expect(!useCase.snapshot().tabs.contains(where: { $0.id == older.id }))
    #expect(useCase.recentlyClosedTabCount == 1)

    guard case .failed = await useCase.retry(retry) else {
        Issue.record("stale retry must be rejected")
        return
    }
    #expect(!useCase.snapshot().tabs.contains(where: { $0.id == older.id }))
    #expect(useCase.recentlyClosedTabCount == 1)
}

@Test @MainActor func recentlyClosedStackIsLIFOAndEvictsBeyondTwentyEntries() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }
    for _ in 0..<21 { _ = await useCase.addScratch() }
    let closedIDs = Array(useCase.snapshot().tabs.dropLast().map(\.id))
    for id in closedIDs { _ = await useCase.close(tabID: id) }
    #expect(useCase.recentlyClosedTabCount == 20)

    for _ in 0..<20 {
        #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    }
    #expect(!useCase.snapshot().tabs.contains(where: { $0.id == closedIDs[0] }))
    #expect(Set(useCase.snapshot().tabs.map(\.id)).isSuperset(of: Set(closedIDs.dropFirst())))
    #expect(useCase.recentlyClosedTabCount == 0)
}

@Test @MainActor func undoCloseWithReopenedFileCreatesDirtyUnboundRecoveryCopy() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }
    let file = FileBinding(
        canonicalPath: "/tmp/reopened.swift",
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .lf,
        observedIdentity: FileIdentity(
            canonicalPath: "/tmp/reopened.swift",
            device: 1,
            inode: 2,
            byteCount: 3,
            modifiedNanoseconds: 4,
            contentToken: "reopened"
        )
    )
    let closed = useCase.snapshot().tabs[0]
    _ = await useCase.bindSavedFile(
        tabID: closed.id,
        binding: file,
        title: "reopened.swift",
        savedRevision: 0
    )
    _ = await useCase.addScratch()
    _ = await useCase.close(tabID: closed.id)
    _ = await useCase.addOpenedFile(binding: file, title: "reopened.swift")

    #expect(await useCase.restoreLastClosedTab() == .applied(.saved))
    let restored = try! #require(useCase.snapshot().tabs.first(where: { $0.id == closed.id }))
    #expect(restored.title == "reopened.swift (restored)")
    #expect(restored.isDirty)
    #expect(restored.fullPath == nil)
    #expect(useCase.snapshot().tabs.filter { $0.fullPath == file.canonicalPath }.count == 1)
}

@Test @MainActor func editorBindingUsesRevisionCheckedIncrementalEdits() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    let initial = useCase.snapshot().activeBuffer!

    #expect(editor.insert("hello") == .accepted(newRevision: 1))
    await Task.yield()
    #expect(useCase.snapshot().activeBuffer?.revision == 1)
    #expect(useCase.snapshot().tabs[0].isDirty)
    #expect(binding.activeTextSnapshot()?.text == "hello")
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: initial.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "stale"
    )) == .rejected(currentRevision: 1))
    #expect(await useCase.flushPersistence() == .saved)
    #expect(await store.storedSession()?.buffers[initial.bufferID]?.revision == 1)
}

@Test @MainActor func rapidIncrementalEditsCoalesceIntoOneOffMainStoreWrite() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let bufferID = useCase.snapshot().activeBuffer!.bufferID
    let savesBeforeEdits = await store.saveCount
    for revision in 0..<3 {
        #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
            bufferID: bufferID,
            expectedRevision: UInt64(revision),
            range: TextEditRange(location: revision, length: 0),
            replacement: "x"
        )) == .accepted(newRevision: UInt64(revision + 1)))
    }
    await useCase.waitForPendingPersistence()
    #expect(await store.saveCount == savesBeforeEdits + 1)
    #expect(await store.storedSession()?.buffers[bufferID]?.revision == 3)
    #expect(useCase.snapshot().persistence == .saved)
}

@Test @MainActor func persistenceFailureIsTypedPublishedAndRollsBackMutation() async {
    var persisted = ScratchSession()
    let originalTab = persisted.addUntitled()
    let store = StoreSpy(session: persisted)
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    await store.setFailure(.unavailable("disk offline"))
    var published: WorkspaceChange?
    useCase.onChange = { published = $0 }

    let outcome = await useCase.addScratch()
    guard case .persistenceFailed(let failure) = outcome else {
        Issue.record("expected typed persistence failure")
        return
    }
    #expect(failure == PersistenceFailure(
        operation: .save,
        cause: .unavailable("disk offline")
    ))
    #expect(useCase.snapshot().tabs.map(\.id) == [originalTab])
    #expect(published?.snapshot.persistence == .failed(failure))
    #expect(published?.failureEvent?.retry == .addScratch)
}

@Test @MainActor func finalClosePersistenceFailureRetainsOriginalTab() async {
    var persisted = ScratchSession()
    let originalTab = persisted.addUntitled()
    let store = StoreSpy(session: persisted)
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    await store.setFailure(.unavailable("session volume offline"))
    var published: [WorkspaceChange] = []
    useCase.onChange = { published.append($0) }

    let outcome = await useCase.close(tabID: originalTab)
    guard case .persistenceFailed(let failure) = outcome else {
        Issue.record("expected close persistence failure")
        return
    }
    #expect(failure.operation == .save)
    #expect(useCase.snapshot().tabs.map(\.id) == [originalTab])
    #expect(published.count == 1)
    #expect(published[0].snapshot.tabs.map(\.id) == [originalTab])
    #expect(published[0].snapshot.persistence == .failed(failure))
}

@Test @MainActor func delayedRestoreDisablesInputAndCannotOverwriteAcceptedTyping() async {
    var restored = ScratchSession()
    restored.addUntitled()
    let store = DelayedLoadStore(session: restored)
    let useCase = ScratchWorkspaceUseCase(store: store)
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }

    let startup = Task { await useCase.start() }
    await store.waitUntilLoadEntered()
    #expect(useCase.snapshot().startup == .restoring)
    #expect(!editor.inputEnabled)
    #expect(editor.insert("must-not-be-lost") == nil)
    let initial = useCase.snapshot().activeBuffer!
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: initial.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "must-not-be-lost"
    )) == .rejected(currentRevision: 0))

    await store.releaseLoad()
    #expect(await startup.value == .saved)
    #expect(useCase.snapshot().startup == .ready)
    #expect(editor.inputEnabled)
    #expect(editor.insert("safe-after-restore") == .accepted(newRevision: 1))
    #expect(binding.activeTextSnapshot()?.text == "safe-after-restore")
}

@Test @MainActor func orderedWriterMakesFlushLatestDurableAgainstReentrantCancellationIgnoringStore() async {
    let store = AdversarialStore()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let bufferID = useCase.snapshot().activeBuffer!.bufferID
    await store.armBlockingCommit()

    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "a"
    )) == .accepted(newRevision: 1))
    await store.waitUntilCommitEntered()
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: bufferID,
        expectedRevision: 1,
        range: TextEditRange(location: 1, length: 0),
        replacement: "b"
    )) == .rejected(currentRevision: 1))
    #expect(await store.maximumConcurrentCommits == 1)
    await store.releaseCommit()
    await useCase.waitForPendingPersistence()
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: bufferID,
        expectedRevision: 1,
        range: TextEditRange(location: 1, length: 0),
        replacement: "b"
    )) == .accepted(newRevision: 2))
    #expect(await useCase.flushPersistence() == .saved)
    #expect(await store.storedRevision(for: bufferID) == 2)
    #expect(await store.maximumConcurrentCommits == 1)
}

@Test @MainActor func editorRetiresOnlySuccessfullyClosedBufferAndPreservesInactiveOrFailedClose() async {
    let store = StoreSpy()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }
    let first = useCase.snapshot().tabs[0]
    #expect(editor.insert("discarded-secret") == .accepted(newRevision: 1))
    _ = await useCase.flushPersistence()
    _ = await useCase.addScratch()
    let secondBuffer = useCase.snapshot().activeBuffer!.bufferID
    #expect(editor.snapshot(for: first.buffer.bufferID)?.text == "discarded-secret")
    #expect(editor.snapshot(for: secondBuffer) != nil)

    await store.setFailure(.unavailable("blocked close"))
    _ = await useCase.close(tabID: first.id, decision: .discard)
    #expect(editor.snapshot(for: first.buffer.bufferID)?.text == "discarded-secret")
    #expect(!editor.retired.contains(first.buffer.bufferID))

    await store.setFailure(nil)
    _ = await useCase.close(tabID: first.id, decision: .discard)
    #expect(editor.snapshot(for: first.buffer.bufferID) == nil)
    #expect(editor.retired == [first.buffer.bufferID])
    #expect(editor.snapshot(for: secondBuffer) != nil)
}

@Test @MainActor func concurrentAddsSerializeWholeReadSaveApplyTransaction() async {
    let store = AdversarialStore()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    await store.armBlockingCommit()

    let first = Task { await useCase.addScratch() }
    await store.waitUntilCommitEntered()
    let second = Task { await useCase.addScratch() }
    await Task.yield()
    await store.releaseCommit()

    #expect(await first.value == .applied(.saved))
    #expect(await second.value == .applied(.saved))
    #expect(useCase.snapshot().tabs.count == 3)
    #expect(await store.storedTabCount() == 3)
}

@Test @MainActor func closeAddAndEditorEditCannotInterleaveIntoLostAcceptedState() async {
    let store = AdversarialStore()
    let useCase = ScratchWorkspaceUseCase(store: store)
    _ = await useCase.start()
    _ = await useCase.addScratch()
    let closingTab = useCase.snapshot().tabs[0].id
    let active = useCase.snapshot().activeBuffer!
    await store.armBlockingCommit()

    let close = Task { await useCase.close(tabID: closingTab) }
    await store.waitUntilCommitEntered()
    let rejectedDuringTransaction = useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: active.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "cannot-be-lost"
    ))
    let add = Task { await useCase.addScratch() }
    await store.releaseCommit()

    guard case .closed = await close.value else {
        Issue.record("close should complete before queued add")
        return
    }
    #expect(await add.value == .applied(.saved))
    #expect(rejectedDuringTransaction == .rejected(currentRevision: 0))
    #expect(useCase.snapshot().tabs.count == 2)
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: active.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "accepted-after-transaction"
    )) == .accepted(newRevision: 1))
    _ = await useCase.flushPersistence()
    #expect(await store.storedRevision(for: active.bufferID) == 1)
    #expect(await store.storedTabCount() == 2)
}

@Test @MainActor func failedLoadKeepsFallbackInputDisabledThroughRecoveryRetry() async {
    var durable = ScratchSession()
    durable.addUntitled()
    let store = StoreSpy(session: durable, failure: .unavailable("load offline"))
    let useCase = ScratchWorkspaceUseCase(store: store)
    let editor = EditorFake()
    let binding = EditorBindingUseCase(workspace: useCase, editor: editor)
    binding.render(useCase.snapshot())
    useCase.onChange = { binding.render($0) }

    guard case .failed = await useCase.start() else {
        Issue.record("initial load should fail")
        return
    }
    #expect(!editor.inputEnabled)
    #expect(editor.insert("must-not-be-accepted") == nil)
    let fallback = useCase.snapshot().activeBuffer!
    #expect(useCase.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: fallback.bufferID,
        expectedRevision: 0,
        range: TextEditRange(location: 0, length: 0),
        replacement: "must-not-be-accepted"
    )) == .rejected(currentRevision: 0))

    await store.setFailure(nil)
    #expect(await useCase.retry(.start) == .saved)
    #expect(useCase.snapshot().startup == .ready)
    #expect(editor.inputEnabled)
    #expect(binding.activeTextSnapshot()?.text == "")
    #expect(editor.insert("accepted-after-recovery") == .accepted(newRevision: 1))
    #expect(binding.activeTextSnapshot()?.text == "accepted-after-recovery")
}

@Test @MainActor func queuedNavigationComputesTargetAfterBlockedMoveCommits() async {
    let store = AdversarialStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    _ = await workspace.start()
    _ = await workspace.addScratch()
    _ = await workspace.addScratch()
    let original = workspace.snapshot().tabs.map(\.id)
    #expect(workspace.snapshot().tabs.last?.isActive == true)
    await store.armBlockingCommit()

    let move = Task { await workspace.moveActiveTab(by: -1) }
    await store.waitUntilCommitEntered()
    let navigate = Task { await workspace.navigateTabs(.previous) }
    await store.releaseCommit()

    #expect(await move.value == .applied(.saved))
    #expect(await navigate.value == .applied(.saved))
    #expect(workspace.snapshot().tabs.map(\.id) == [original[0], original[2], original[1]])
    #expect(workspace.snapshot().tabs.first?.isActive == true)
    #expect(await store.maximumConcurrentCommits == 1)
}

@Test @MainActor func keyboardCommandsUseVisualOrderMRUAndSerializedMove() async {
    let workspace = ScratchWorkspaceUseCase(store: StoreSpy())
    _ = await workspace.start()
    _ = await workspace.addScratch()
    _ = await workspace.addScratch()
    let ids = workspace.snapshot().tabs.map(\.id)
    _ = await workspace.activate(tabID: ids[0])
    _ = await workspace.activate(tabID: ids[1])
    _ = await workspace.activate(tabID: ids[2])

    #expect(await workspace.navigateTabs(.lastUsed) == .applied(.saved))
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == ids[1])
    #expect(await workspace.navigateTabs(.next) == .applied(.saved))
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == ids[2])
    #expect(await workspace.navigateTabs(.previous) == .applied(.saved))
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == ids[1])
    #expect(await workspace.moveActiveTab(by: -1) == .applied(.saved))
    #expect(workspace.snapshot().tabs.map(\.id) == [ids[1], ids[0], ids[2]])
}
