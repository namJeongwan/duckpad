import DuckpadApplication
import DuckpadDomain
import Testing

private actor CloseStore: SessionStore {
    private var session: ScratchSession?
    private var generation = PersistenceGeneration(rawValue: 0)

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: generation) }
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        guard generation > self.generation else {
            return .superseded(durableGeneration: self.generation)
        }
        self.session = session
        self.generation = generation
        return .committed
    }
}

@MainActor
private final class SuspendedDecision {
    private var continuation: CheckedContinuation<CloseDecision, Never>?
    private(set) var calls = 0

    func decide(tab: TabSnapshot, saveAvailable: Bool) async -> CloseDecision {
        calls += 1
        if calls > 1 { return .cancel }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPresented() async {
        while continuation == nil { await Task.yield() }
    }

    func resolve(_ decision: CloseDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

@MainActor
private final class DecisionSequence {
    private var decisions: [CloseDecision]
    private(set) var reviewed: [TabID] = []

    init(_ decisions: [CloseDecision]) { self.decisions = decisions }

    func decide(tab: TabSnapshot, saveAvailable: Bool) async -> CloseDecision {
        reviewed.append(tab.id)
        return decisions.isEmpty ? .cancel : decisions.removeFirst()
    }
}

@MainActor
private func makeDirtyWorkspace() async -> (ScratchWorkspaceUseCase, TabSnapshot) {
    let workspace = ScratchWorkspaceUseCase(store: CloseStore())
    _ = await workspace.start()
    let tab = workspace.snapshot().tabs[0]
    #expect(workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: tab.buffer.bufferID,
        expectedRevision: tab.buffer.revision,
        range: TextEditRange(location: 0, length: 0),
        replacement: "first"
    )) == .accepted(newRevision: 1))
    return (workspace, workspace.snapshot().tabs[0])
}

@MainActor
private func makeDirtyWorkspace(count: Int) async -> (ScratchWorkspaceUseCase, [TabSnapshot]) {
    let workspace = ScratchWorkspaceUseCase(store: CloseStore())
    _ = await workspace.start()
    if count > 1 {
        for _ in 1..<count { _ = await workspace.addScratch() }
    }
    let cleanTabs = workspace.snapshot().tabs
    for tab in cleanTabs {
        #expect(workspace.acceptEditorEdit(EditorIncrementalEdit(
            bufferID: tab.buffer.bufferID,
            expectedRevision: tab.buffer.revision,
            range: TextEditRange(location: 0, length: 0),
            replacement: "dirty"
        )) == .accepted(newRevision: tab.buffer.revision + 1))
    }
    return (workspace, workspace.snapshot().tabs)
}

@Test @MainActor func editWhileDirtyDecisionIsSuspendedForcesFreshReview() async {
    let (workspace, tab) = await makeDirtyWorkspace()
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = SuspendedDecision()
    let closing = Task {
        await coordinator.close(
            tabIDs: [tab.id],
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    await decisions.waitUntilPresented()
    #expect(workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: tab.buffer.bufferID,
        expectedRevision: 1,
        range: TextEditRange(location: 5, length: 0),
        replacement: "-new"
    )) == .accepted(newRevision: 2))

    decisions.resolve(.discard)
    #expect(await closing.value == .cancelled)
    #expect(decisions.calls == 2)
    #expect(workspace.snapshot().tabs.first?.id == tab.id)
    #expect(workspace.snapshot().tabs.first?.buffer.revision == 2)
    #expect(workspace.snapshot().tabs.first?.isDirty == true)
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func concurrentDuplicateCloseRequestsShareOneDecision() async {
    let (workspace, tab) = await makeDirtyWorkspace()
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = SuspendedDecision()
    let first = Task {
        await coordinator.close(
            tabIDs: [tab.id],
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    await decisions.waitUntilPresented()
    let second = Task {
        await coordinator.close(
            tabIDs: [tab.id],
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    decisions.resolve(.cancel)

    #expect(await first.value == .cancelled)
    #expect(await second.value == .completed)
    #expect(decisions.calls == 1)
    #expect(workspace.snapshot().tabs.first?.id == tab.id)
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func commandCloseAndTerminationReviewJoinOneDirtyDecision() async {
    let (workspace, tab) = await makeDirtyWorkspace()
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = SuspendedDecision()
    let command = Task {
        await coordinator.close(
            tabIDs: [tab.id],
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    await decisions.waitUntilPresented()
    let termination = Task {
        await coordinator.reviewDirtyForTermination(
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    decisions.resolve(.cancel)

    #expect(await command.value == .cancelled)
    #expect(await termination.value == .cancelled)
    #expect(decisions.calls == 1)
    #expect(workspace.snapshot().tabs.first?.id == tab.id)
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func expectedRevisionIsCheckedInsideCloseTransaction() async {
    let (workspace, tab) = await makeDirtyWorkspace()
    #expect(workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: tab.buffer.bufferID,
        expectedRevision: 1,
        range: TextEditRange(location: 5, length: 0),
        replacement: "-new"
    )) == .accepted(newRevision: 2))

    #expect(await workspace.close(
        tabID: tab.id,
        decision: .discard,
        expectedRevision: 1
    ) == .reviewStale(currentRevision: 2))
    #expect(workspace.snapshot().tabs.first?.id == tab.id)
    #expect(workspace.snapshot().tabs.first?.isDirty == true)
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func bulkCloseStopsAtCancelAfterKeepingAlreadyDecidedClosures() async {
    let (workspace, tabs) = await makeDirtyWorkspace(count: 3)
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = DecisionSequence([.discard, .cancel])

    #expect(await coordinator.close(
        tabIDs: tabs.map(\.id),
        saveAvailable: false,
        decision: decisions.decide,
        save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
    ) == .cancelled)
    #expect(decisions.reviewed == [tabs[0].id, tabs[1].id])
    #expect(workspace.snapshot().tabs.map(\.id) == [tabs[1].id, tabs[2].id])
    #expect(workspace.snapshot().tabs.allSatisfy { $0.isDirty })
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func bulkCloseSaveFailureLeavesCurrentAndLaterTargetsOpen() async {
    let (workspace, tabs) = await makeDirtyWorkspace(count: 3)
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = DecisionSequence([.save])
    let outcome = await coordinator.close(
        tabIDs: tabs.map(\.id),
        saveAvailable: true,
        decision: decisions.decide,
        save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("injected"))) }
    )

    guard case .failed = outcome else {
        Issue.record("save failure must stop the batch")
        return
    }
    #expect(decisions.reviewed == [tabs[0].id])
    #expect(workspace.snapshot().tabs.map(\.id) == tabs.map(\.id))
    #expect(workspace.snapshot().tabs.allSatisfy { $0.isDirty })
    await workspace.waitForPendingPersistence()
}

@Test @MainActor func bulkCloseSkipsTargetClosedWhileEarlierDecisionWasSuspended() async {
    let (workspace, tabs) = await makeDirtyWorkspace(count: 2)
    let coordinator = TabCloseCoordinator(workspace: workspace)
    let decisions = SuspendedDecision()
    let bulk = Task {
        await coordinator.close(
            tabIDs: tabs.map(\.id),
            saveAvailable: false,
            decision: decisions.decide,
            save: { _, _ in .failed(PersistenceFailure(operation: .save, cause: .unavailable("unused"))) }
        )
    }
    await decisions.waitUntilPresented()
    let concurrentClose = await workspace.close(
        tabID: tabs[1].id,
        decision: .discard,
        expectedRevision: tabs[1].buffer.revision
    )
    guard case .closed = concurrentClose else {
        Issue.record("concurrent stale target should close independently")
        return
    }
    decisions.resolve(.discard)

    #expect(await bulk.value == .completed)
    #expect(decisions.calls == 1)
    #expect(!workspace.snapshot().tabs.contains(where: { tabs.map(\.id).contains($0.id) }))
    await workspace.waitForPendingPersistence()
}
