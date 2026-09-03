import DuckpadDomain
import Foundation

public struct TabSnapshot: Equatable, Sendable {
    public let id: TabID
    public let title: String
    public let isActive: Bool
    public let isDirty: Bool
    public let isPinned: Bool
    public let buffer: EditorBufferDescriptor
    public let fullPath: String?

    public init(id: TabID, title: String, isActive: Bool, isDirty: Bool, isPinned: Bool, buffer: EditorBufferDescriptor, fullPath: String? = nil) {
        self.id = id
        self.title = title
        self.isActive = isActive
        self.isDirty = isDirty
        self.isPinned = isPinned
        self.buffer = buffer
        self.fullPath = fullPath
    }
}

public enum PersistenceOperation: String, Equatable, Sendable { case load, save }

public struct PersistenceFailure: Error, Equatable, Sendable {
    public let operation: PersistenceOperation
    public let cause: SessionStoreError

    public init(operation: PersistenceOperation, cause: SessionStoreError) {
        self.operation = operation
        self.cause = cause
    }
}

public enum PersistenceState: Equatable, Sendable {
    case idle, pending, saved
    case failed(PersistenceFailure)
}

public enum WorkspaceStartupState: Equatable, Sendable {
    case restoring
    case ready
    case failed(PersistenceFailure)
}

public enum PersistenceOutcome: Equatable, Sendable {
    case saved
    case failed(PersistenceFailure)
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public let sessionID: SessionID
    public let tabs: [TabSnapshot]
    public let activeBuffer: EditorBufferDescriptor?
    public let persistence: PersistenceState
    public let startup: WorkspaceStartupState

    public init(sessionID: SessionID, tabs: [TabSnapshot], activeBuffer: EditorBufferDescriptor?, persistence: PersistenceState, startup: WorkspaceStartupState) {
        self.sessionID = sessionID
        self.tabs = tabs
        self.activeBuffer = activeBuffer
        self.persistence = persistence
        self.startup = startup
    }
}

public enum PersistenceRetry: Equatable, Sendable {
    case start
    case saveCurrent
    case addScratch
    case activate(TabID)
    case close(TabID, CloseDecision?, expectedRevision: UInt64?)
    case restoreClosedTab(UUID)
    case moveTab(TabID, Int)
    case pinTab(TabID, Bool)
    case languageOverride(TabID, LanguageOverride)
}

public struct PersistenceFailureEvent: Equatable, Sendable {
    public let id: UUID
    public let failure: PersistenceFailure
    public let retry: PersistenceRetry

    public init(id: UUID = UUID(), failure: PersistenceFailure, retry: PersistenceRetry) {
        self.id = id
        self.failure = failure
        self.retry = retry
    }
}

public enum WorkspaceChangeKind: Equatable, Sendable {
    case reset
    case tabInserted(index: Int)
    case activeTabChanged(previousIndex: Int?, currentIndex: Int)
    case tabUpdated(index: Int)
    case bufferEdited(index: Int)
    case tabRemoved(index: Int, retiredBufferID: BufferID)
    case tabsReordered(fromIndex: Int, toIndex: Int)
    case persistence
}

public enum TabNavigationCommand: Equatable, Sendable {
    case next
    case previous
    case lastUsed
}

public enum TabCloseScope: Equatable, Sendable {
    case current
    case all
    case others
    case left
    case right
    case unchanged
    case unpinned
}

public struct WorkspaceChange: Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    public let kind: WorkspaceChangeKind
    public let failureEvent: PersistenceFailureEvent?

    public init(snapshot: WorkspaceSnapshot, kind: WorkspaceChangeKind, failureEvent: PersistenceFailureEvent? = nil) {
        self.snapshot = snapshot
        self.kind = kind
        self.failureEvent = failureEvent
    }
}

public enum WorkspaceActionOutcome: Equatable, Sendable {
    case applied(PersistenceOutcome)
    case persistenceFailed(PersistenceFailure)
    case rejected(SessionError)
}

public enum CloseDecision: Equatable, Sendable { case discard, cancel, save }

public enum CloseOutcome: Equatable, Sendable {
    case requiresDecision(saveAvailable: Bool)
    case cancelled
    case saveUnavailable
    case reviewStale(currentRevision: UInt64)
    case closed(activeTabID: TabID, replacementCreated: Bool, persistence: PersistenceOutcome)
    case rejected(SessionError)
    case persistenceFailed(PersistenceFailure)
}

public struct EditorBatchReservation: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let bufferID: BufferID
    fileprivate let expectedRevision: UInt64
    fileprivate let editCount: Int
}

private actor OrderedSessionWriter {
    private let store: any SessionStore
    private var tail: Task<PersistenceOutcome, Never>?

    init(store: any SessionStore) { self.store = store }

    func enqueue(_ session: ScratchSession, generation: PersistenceGeneration) async -> PersistenceOutcome {
        let predecessor = tail
        let store = self.store
        let task = Task.detached(priority: .utility) { () -> PersistenceOutcome in
            _ = await predecessor?.value
            do {
                switch try await store.commitSession(session, generation: generation) {
                case .committed:
                    return .saved
                case .superseded(let durable) where durable >= generation:
                    return .saved
                case .superseded(let durable):
                    return .failed(PersistenceFailure(
                        operation: .save,
                        cause: .corrupt("store reported older durable generation \(durable.rawValue)")
                    ))
                }
            } catch let error as SessionStoreError {
                return .failed(PersistenceFailure(operation: .save, cause: error))
            } catch {
                preconditionFailure("SessionStore only throws SessionStoreError")
            }
        }
        tail = task
        return await task.value
    }
}

@MainActor
public final class ScratchWorkspaceUseCase {
    private struct RecentlyClosedTab {
        let id: UUID
        let state: ClosedTabState
        let editor: EditorRecoveryCapture
        let automaticReplacement: ClosedTabState?
    }

    private static let recentlyClosedLimit = 100
    private let store: any SessionStore
    private let writer: OrderedSessionWriter
    private var session: ScratchSession
    private var persistenceState: PersistenceState = .idle
    private var startupState: WorkspaceStartupState = .restoring
    private var generation = PersistenceGeneration(rawValue: 0)
    private var pendingEditToken: UUID?
    private var pendingEditTask: Task<Void, Never>?
    private var hasStarted = false
    private var transactionBusy = false
    private var editorBatchReservationID: UUID?
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeRecoveryCommitter: (@MainActor (ScratchSession) async -> RecoveryOutcome)?
    private var captureClosedBuffer: (@MainActor (BufferID) -> EditorRecoveryCapture?)?
    private var installClosedBuffer: (@MainActor (EditorRecoverySnapshot) -> Void)?
    private var retireClosedBuffer: (@MainActor (BufferID) -> Void)?
    private var recentlyClosedTabs: [RecentlyClosedTab] = []

    public var onChange: ((WorkspaceChange) -> Void)?

    public init(store: any SessionStore) {
        self.store = store
        writer = OrderedSessionWriter(store: store)
        var initial = ScratchSession()
        initial.addUntitled()
        session = initial
    }

    public func installCloseRecoveryCommitter(
        _ committer: @escaping @MainActor (ScratchSession) async -> RecoveryOutcome
    ) {
        closeRecoveryCommitter = committer
    }

    public func installClosedTabBufferBridge(
        capture: @escaping @MainActor (BufferID) -> EditorRecoveryCapture?,
        install: @escaping @MainActor (EditorRecoverySnapshot) -> Void,
        retire: @escaping @MainActor (BufferID) -> Void
    ) {
        captureClosedBuffer = capture
        installClosedBuffer = install
        retireClosedBuffer = retire
    }

    public var canRestoreRecentlyClosedTab: Bool {
        !recentlyClosedTabs.isEmpty && installClosedBuffer != nil
    }

    public var recentlyClosedTabCount: Int { recentlyClosedTabs.count }

    @discardableResult
    public func start() async -> PersistenceOutcome {
        await start(restoring: nil, prepareForReady: {})
    }

    @discardableResult
    public func start(
        restoring stored: StoredSession,
        prepareForReady: @MainActor () -> Void
    ) async -> PersistenceOutcome {
        await start(restoring: Optional(stored), prepareForReady: prepareForReady)
    }

    private func start(
        restoring supplied: StoredSession?,
        prepareForReady: @MainActor () -> Void
    ) async -> PersistenceOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard !hasStarted else {
            if case .failed(let failure) = startupState { return .failed(failure) }
            return .saved
        }
        hasStarted = true
        startupState = .restoring
        publish(.reset)
        do {
            let available: StoredSession?
            if let supplied { available = supplied }
            else { available = try await store.loadSession() }
            if let stored = available {
                generation = stored.generation
                var loaded = stored.session
                let needsSave = loaded.tabs.isEmpty
                if needsSave { loaded.addUntitled() }
                session = loaded
                if needsSave {
                    let outcome = await save(loaded)
                    if case .saved = outcome { prepareForReady() }
                    return finishStart(outcome)
                }
                prepareForReady()
                persistenceState = .saved
                startupState = .ready
                publish(.reset)
                return .saved
            }
            return finishStart(await save(session))
        } catch let error {
            let failure = PersistenceFailure(operation: .load, cause: error)
            persistenceState = .failed(failure)
            startupState = .failed(failure)
            publishFailure(failure, retry: .start)
            return .failed(failure)
        }
    }

    @discardableResult
    public func retry(_ retry: PersistenceRetry) async -> PersistenceOutcome {
        switch retry {
        case .start:
            hasStarted = false
            return await start()
        case .saveCurrent:
            return await saveCurrentAndPublish(retry: .saveCurrent)
        case .addScratch:
            return outcome(from: await addScratch())
        case .activate(let id):
            return outcome(from: await activate(tabID: id))
        case .close(let id, let decision, let expectedRevision):
            return outcome(from: await close(tabID: id, decision: decision, expectedRevision: expectedRevision))
        case .restoreClosedTab(let entryID):
            return outcome(from: await restoreLastClosedTab(expectedEntryID: entryID))
        case .moveTab(let id, let index):
            return outcome(from: await moveTab(id, to: index))
        case .pinTab(let id, let pinned):
            return outcome(from: await setPinned(id, isPinned: pinned))
        case .languageOverride(let id, let override):
            return outcome(from: await setLanguageOverride(override, for: id))
        }
    }

    @discardableResult
    public func addScratch() async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        candidate.addUntitled()
        return await persistMutation(candidate, kind: .tabInserted(index: candidate.tabs.count - 1), retry: .addScratch)
    }

    @discardableResult
    public func activate(tabID: TabID) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        return await activateLocked(tabID: tabID)
    }

    private func activateLocked(tabID: TabID) async -> WorkspaceActionOutcome {
        var candidate = session
        let previous = candidate.tabs.firstIndex { $0.id == candidate.activeTabID }
        do {
            try candidate.activate(tabID: tabID)
            let current = candidate.tabs.firstIndex { $0.id == tabID }!
            return await persistMutation(candidate, kind: .activeTabChanged(previousIndex: previous, currentIndex: current), retry: .activate(tabID))
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func navigateTabs(_ command: TabNavigationCommand) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard !session.tabs.isEmpty else { return .rejected(.invalidRecoveryState("no tabs")) }
        let activeIndex = session.tabs.firstIndex(where: { $0.id == session.activeTabID }) ?? 0
        let target: TabID
        switch command {
        case .next:
            target = session.tabs[(activeIndex + 1) % session.tabs.count].id
        case .previous:
            target = session.tabs[(activeIndex - 1 + session.tabs.count) % session.tabs.count].id
        case .lastUsed:
            target = session.lastUsedTabID
                ?? session.tabs[(activeIndex - 1 + session.tabs.count) % session.tabs.count].id
        }
        return await activateLocked(tabID: target)
    }

    @discardableResult
    public func moveTab(_ tabID: TabID, to proposedIndex: Int) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        guard let source = candidate.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .rejected(.unknownTab(tabID))
        }
        do {
            let destination = try candidate.moveTab(tabID: tabID, to: proposedIndex)
            guard source != destination else { return .applied(.saved) }
            return await persistMutation(
                candidate,
                kind: .tabsReordered(fromIndex: source, toIndex: destination),
                retry: .moveTab(tabID, proposedIndex)
            )
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func moveActiveTab(by offset: Int) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard let active = session.activeTabID,
              let index = session.tabs.firstIndex(where: { $0.id == active }) else {
            return .rejected(.invalidRecoveryState("no active tab"))
        }
        let destination = min(max(index + offset, 0), session.tabs.count - 1)
        var candidate = session
        do {
            let actual = try candidate.moveTab(tabID: active, to: destination)
            guard actual != index else { return .applied(.saved) }
            return await persistMutation(
                candidate,
                kind: .tabsReordered(fromIndex: index, toIndex: actual),
                retry: .moveTab(active, destination)
            )
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func setPinned(_ tabID: TabID, isPinned: Bool) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        guard let source = candidate.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .rejected(.unknownTab(tabID))
        }
        do {
            let destination = try candidate.setPinned(tabID: tabID, isPinned: isPinned)
            guard session.tabs[source].isPinned != isPinned else { return .applied(.saved) }
            return await persistMutation(
                candidate,
                kind: .tabsReordered(fromIndex: source, toIndex: destination),
                retry: .pinTab(tabID, isPinned)
            )
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    public func tabIDs(for scope: TabCloseScope, relativeTo anchor: TabID) -> [TabID] {
        guard let anchorIndex = session.tabs.firstIndex(where: { $0.id == anchor }) else { return [] }
        switch scope {
        case .current:
            return [anchor]
        case .all:
            return session.tabs.filter { !$0.isPinned }.map(\.id)
        case .others:
            return session.tabs.filter { $0.id != anchor && !$0.isPinned }.map(\.id)
        case .left:
            return session.tabs[..<anchorIndex].filter { !$0.isPinned }.map(\.id)
        case .right:
            return session.tabs[(anchorIndex + 1)...].filter { !$0.isPinned }.map(\.id)
        case .unchanged:
            return session.tabs.compactMap { tab in
                guard !tab.isPinned,
                      let buffer = try? session.buffer(for: tab.id),
                      !buffer.isDirty else { return nil }
                return tab.id
            }
        case .unpinned:
            return session.tabs.filter { !$0.isPinned }.map(\.id)
        }
    }

    public func close(
        tabID: TabID,
        decision: CloseDecision? = nil,
        expectedRevision: UInt64? = nil
    ) async -> CloseOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard let removedIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .rejected(.unknownTab(tabID))
        }
        let buffer: BufferMetadata
        do { buffer = try session.buffer(for: tabID) }
        catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
        if let expectedRevision, buffer.revision != expectedRevision {
            return .reviewStale(currentRevision: buffer.revision)
        }

        if buffer.isDirty {
            switch decision {
            case nil: return .requiresDecision(saveAvailable: false)
            case .cancel: return .cancelled
            case .save: return .saveUnavailable
            case .discard: break
            }
        }

        let closedState = try? session.closedTabState(for: tabID)
        let closedEditor = captureClosedBuffer?(buffer.id)
        let restorable = closedState.flatMap { state -> RecentlyClosedTab? in
            guard let closedEditor,
                  closedEditor.bufferID == state.buffer.id,
                  closedEditor.revision == state.buffer.revision else { return nil }
            return RecentlyClosedTab(
                id: UUID(),
                state: state,
                editor: closedEditor,
                automaticReplacement: nil
            )
        }

        var candidate = session
        do {
            _ = try candidate.close(tabID: tabID, discardingDirty: buffer.isDirty && decision == .discard)
            let replacementCreated = candidate.tabs.isEmpty
            if replacementCreated { candidate.addUntitled() }
            switch await save(candidate) {
            case .saved:
                if let closeRecoveryCommitter {
                    switch await closeRecoveryCommitter(candidate) {
                    case .saved:
                        break
                    case .failed(let error):
                        let failure = PersistenceFailure(operation: .save, cause: error)
                        persistenceState = .failed(failure)
                        publishFailure(failure, retry: .close(tabID, decision, expectedRevision: expectedRevision))
                        return .persistenceFailed(failure)
                    }
                }
                session = candidate
                if let restorable {
                    recentlyClosedTabs.append(RecentlyClosedTab(
                        id: restorable.id,
                        state: restorable.state,
                        editor: restorable.editor,
                        automaticReplacement: replacementCreated
                            ? candidate.activeTabID.flatMap { try? candidate.closedTabState(for: $0) }
                            : nil
                    ))
                    if recentlyClosedTabs.count > Self.recentlyClosedLimit {
                        recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedLimit)
                    }
                }
                persistenceState = .saved
                publish(.tabRemoved(index: removedIndex, retiredBufferID: buffer.id))
                return .closed(activeTabID: candidate.activeTabID!, replacementCreated: replacementCreated, persistence: .saved)
            case .failed(let failure):
                persistenceState = .failed(failure)
                publishFailure(failure, retry: .close(tabID, decision, expectedRevision: expectedRevision))
                return .persistenceFailed(failure)
            }
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func restoreLastClosedTab(expectedEntryID: UUID? = nil) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard let closed = recentlyClosedTabs.last,
              expectedEntryID == nil || expectedEntryID == closed.id,
              let installClosedBuffer,
              let retireClosedBuffer else {
            return .rejected(.invalidRecoveryState("no recently closed tab"))
        }

        let editorSnapshot: EditorRecoverySnapshot
        do {
            editorSnapshot = try await Task.detached(priority: .utility) {
                try closed.editor.materializedSnapshot()
            }.value
        } catch {
            return .rejected(.invalidRecoveryState("invalid recently closed editor capture"))
        }
        installClosedBuffer(editorSnapshot)
        var candidate = session
        do {
            var retiredReplacementBufferID: BufferID?
            if let replacement = closed.automaticReplacement,
               let replacementID = candidate.activeTabID,
               candidate.tabs.count == 1,
               candidate.tabs[0].id == replacementID,
               let currentReplacement = try? candidate.closedTabState(for: replacementID),
               currentReplacement == replacement,
               let replacementEditor = captureClosedBuffer?(replacement.buffer.id),
               replacementEditor.bufferID == replacement.buffer.id,
               replacementEditor.baseRevision == 0,
               replacementEditor.revision == 0,
               replacementEditor.baseUTF8.isEmpty,
               replacementEditor.deltas.isEmpty,
               replacementEditor.viewState == EditorViewState() {
                retiredReplacementBufferID = replacement.buffer.id
                _ = try candidate.close(tabID: replacementID)
            }
            let restorationState: ClosedTabState
            if let binding = closed.state.fileBinding,
               candidate.tabID(canonicalPath: binding.canonicalPath) != nil {
                restorationState = ClosedTabState(
                    originalIndex: closed.state.originalIndex,
                    tab: closed.state.tab,
                    document: ScratchDocument(
                        id: closed.state.document.id,
                        bufferID: closed.state.document.bufferID,
                        title: "\(closed.state.document.title) (restored)"
                    ),
                    buffer: BufferMetadata(
                        id: closed.state.buffer.id,
                        revision: closed.state.buffer.revision,
                        isDirty: true
                    ),
                    fileBinding: nil,
                    languageOverride: closed.state.languageOverride
                )
            } else {
                restorationState = closed.state
            }
            let index = try candidate.restoreClosedTab(restorationState)
            switch await save(candidate) {
            case .saved:
                if let closeRecoveryCommitter {
                    switch await closeRecoveryCommitter(candidate) {
                    case .saved:
                        break
                    case .failed(let error):
                        retireClosedBuffer(editorSnapshot.bufferID)
                        let failure = PersistenceFailure(operation: .save, cause: error)
                        persistenceState = .failed(failure)
                        publishFailure(failure, retry: .restoreClosedTab(closed.id))
                        return .persistenceFailed(failure)
                    }
                }
                session = candidate
                recentlyClosedTabs.removeLast()
                persistenceState = .saved
                if let retiredReplacementBufferID {
                    retireClosedBuffer(retiredReplacementBufferID)
                    publish(.reset)
                } else {
                    publish(.tabInserted(index: index))
                }
                return .applied(.saved)
            case .failed(let failure):
                retireClosedBuffer(editorSnapshot.bufferID)
                persistenceState = .failed(failure)
                publishFailure(failure, retry: .restoreClosedTab(closed.id))
                return .persistenceFailed(failure)
            }
        } catch let error as SessionError {
            retireClosedBuffer(editorSnapshot.bufferID)
            return .rejected(error)
        } catch {
            preconditionFailure("ScratchSession only throws SessionError")
        }
    }

    public func acceptEditorEdit(_ edit: EditorIncrementalEdit) -> EditorEditOutcome {
        guard startupState == .ready, !transactionBusy else {
            return .rejected(currentRevision: edit.expectedRevision)
        }
        guard let index = session.tabs.firstIndex(where: { (try? session.buffer(for: $0.id).id) == edit.bufferID }) else {
            return .rejected(currentRevision: edit.expectedRevision)
        }
        let tabID = session.tabs[index].id
        do {
            let revision = try session.recordEdit(in: tabID, expectedRevision: edit.expectedRevision)
            persistenceState = .pending
            schedulePersistence()
            publish(.bufferEdited(index: index))
            return .accepted(newRevision: revision)
        } catch {
            let current = (try? session.buffer(for: tabID).revision) ?? edit.expectedRevision
            return .rejected(currentRevision: current)
        }
    }

    public func reserveEditorBatch(
        bufferID: BufferID,
        expectedRevision: UInt64,
        editCount: Int
    ) async -> EditorBatchReservation? {
        guard editCount > 0, UInt64(editCount) <= UInt64.max - expectedRevision else { return nil }
        await acquireTransaction()
        guard !Task.isCancelled, startupState == .ready,
              let activeTab = session.activeTabID,
              let buffer = try? session.buffer(for: activeTab),
              buffer.id == bufferID, buffer.revision == expectedRevision else {
            releaseTransaction()
            return nil
        }
        let reservation = EditorBatchReservation(
            id: UUID(), bufferID: bufferID,
            expectedRevision: expectedRevision, editCount: editCount
        )
        editorBatchReservationID = reservation.id
        return reservation
    }

    public func commitEditorBatch(
        _ reservation: EditorBatchReservation,
        edits: [EditorIncrementalEdit]
    ) -> EditorEditOutcome {
        guard editorBatchReservationID == reservation.id,
              edits.count == reservation.editCount,
              let activeTab = session.activeTabID,
              let index = session.tabs.firstIndex(where: { $0.id == activeTab }) else {
            return .rejected(currentRevision: snapshot().activeBuffer?.revision ?? reservation.expectedRevision)
        }
        var candidate = session
        var expected = reservation.expectedRevision
        do {
            for edit in edits {
                guard edit.bufferID == reservation.bufferID, edit.expectedRevision == expected else {
                    return .rejected(currentRevision: (try? session.buffer(for: activeTab).revision) ?? expected)
                }
                expected = try candidate.recordEdit(in: activeTab, expectedRevision: expected)
            }
            session = candidate
            editorBatchReservationID = nil
            releaseTransaction()
            persistenceState = .pending
            schedulePersistence()
            publish(.bufferEdited(index: index))
            return .accepted(newRevision: expected)
        } catch {
            return .rejected(currentRevision: (try? session.buffer(for: activeTab).revision) ?? expected)
        }
    }

    public func cancelEditorBatch(_ reservation: EditorBatchReservation) {
        guard editorBatchReservationID == reservation.id else { return }
        editorBatchReservationID = nil
        releaseTransaction()
    }

    @discardableResult
    public func flushPersistence() async -> PersistenceOutcome {
        pendingEditToken = nil
        let outcome = await saveCurrentAndPublish(retry: .saveCurrent)
        await pendingEditTask?.value
        pendingEditTask = nil
        return outcome
    }

    public func waitForPendingPersistence() async { await pendingEditTask?.value }

    public func snapshot() -> WorkspaceSnapshot {
        let tabs = session.tabs.compactMap { tab -> TabSnapshot? in
            guard let document = try? session.document(for: tab.id), let buffer = try? session.buffer(for: tab.id) else { return nil }
            return TabSnapshot(
                id: tab.id,
                title: document.title,
                isActive: tab.id == session.activeTabID,
                isDirty: buffer.isDirty,
                isPinned: tab.isPinned,
                buffer: EditorBufferDescriptor(bufferID: buffer.id, revision: buffer.revision),
                fullPath: session.fileBindings[document.id]?.canonicalPath
            )
        }
        return WorkspaceSnapshot(sessionID: session.id, tabs: tabs, activeBuffer: tabs.first(where: \.isActive)?.buffer, persistence: persistenceState, startup: startupState)
    }

    public func recoverySession() -> ScratchSession { session }

    public func tabID(canonicalPath: String) -> TabID? {
        session.tabID(canonicalPath: canonicalPath)
    }

    public func activeFileContext() -> FileWorkspaceContext? {
        guard let tabID = session.activeTabID else { return nil }
        return fileContext(tabID: tabID)
    }

    public func activeLanguageContext() -> ActiveLanguageContext? {
        guard let tabID = session.activeTabID,
              let document = try? session.document(for: tabID),
              let buffer = try? session.buffer(for: tabID) else { return nil }
        let binding = try? session.fileBinding(for: tabID)
        return ActiveLanguageContext(
            tabID: tabID,
            documentID: document.id,
            buffer: EditorBufferDescriptor(bufferID: buffer.id, revision: buffer.revision),
            filename: binding?.canonicalPath ?? document.title,
            override: (try? session.languageOverride(for: tabID)) ?? .automatic
        )
    }

    @discardableResult
    public func setLanguageOverride(
        _ override: LanguageOverride,
        for tabID: TabID
    ) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        do {
            try candidate.setLanguageOverride(override, for: tabID)
            guard let index = candidate.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .rejected(.unknownTab(tabID))
            }
            return await persistMutation(
                candidate,
                kind: .tabUpdated(index: index),
                retry: .languageOverride(tabID, override)
            )
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    public func fileContext(tabID: TabID) -> FileWorkspaceContext? {
        guard let document = try? session.document(for: tabID),
              let buffer = try? session.buffer(for: tabID) else { return nil }
        return FileWorkspaceContext(
            tabID: tabID,
            title: document.title,
            buffer: EditorBufferDescriptor(bufferID: buffer.id, revision: buffer.revision),
            binding: try? session.fileBinding(for: tabID)
        )
    }

    @discardableResult
    public func addOpenedFile(binding: FileBinding, title: String) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        do {
            _ = try candidate.addFile(binding: binding, title: title)
            return await persistMutation(candidate, kind: .tabInserted(index: candidate.tabs.count - 1), retry: .saveCurrent)
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func bindSavedFile(
        tabID: TabID,
        binding: FileBinding,
        title: String,
        savedRevision: UInt64
    ) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        do {
            try candidate.bindFile(tabID: tabID, binding: binding, title: title, cleanAtRevision: savedRevision)
            guard let index = candidate.tabs.firstIndex(where: { $0.id == tabID }) else { return .rejected(.unknownTab(tabID)) }
            return await persistMutation(candidate, kind: .tabUpdated(index: index), retry: .saveCurrent)
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func bindSavedFileIfCurrent(
        tabID: TabID,
        binding: FileBinding,
        title: String,
        savedRevision: UInt64,
        expectedBufferID: BufferID,
        expectedBinding: FileBinding?
    ) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        do {
            let document = try candidate.document(for: tabID)
            let buffer = try candidate.buffer(for: tabID)
            guard buffer.id == expectedBufferID,
                  try candidate.fileBinding(for: tabID) == expectedBinding else {
                return .rejected(.fileBindingConflict(documentID: document.id))
            }
            try candidate.bindFile(
                tabID: tabID,
                binding: binding,
                title: title,
                cleanAtRevision: savedRevision
            )
            guard let index = candidate.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .rejected(.unknownTab(tabID))
            }
            return await persistMutation(
                candidate,
                kind: .tabUpdated(index: index),
                retry: .saveCurrent
            )
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    @discardableResult
    public func replaceFileContents(
        tabID: TabID,
        binding: FileBinding,
        title: String,
        expectedRevision: UInt64,
        expectedBinding: FileBinding?
    ) async -> WorkspaceActionOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        var candidate = session
        do {
            _ = try candidate.replaceFileContents(
                tabID: tabID,
                binding: binding,
                title: title,
                expectedRevision: expectedRevision,
                expectedBinding: expectedBinding
            )
            guard let index = candidate.tabs.firstIndex(where: { $0.id == tabID }) else { return .rejected(.unknownTab(tabID)) }
            return await persistMutation(candidate, kind: .tabUpdated(index: index), retry: .saveCurrent)
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    private func persistMutation(_ candidate: ScratchSession, kind: WorkspaceChangeKind, retry: PersistenceRetry) async -> WorkspaceActionOutcome {
        switch await save(candidate) {
        case .saved:
            session = candidate
            persistenceState = .saved
            publish(kind)
            return .applied(.saved)
        case .failed(let failure):
            persistenceState = .failed(failure)
            publishFailure(failure, retry: retry)
            return .persistenceFailed(failure)
        }
    }

    private func finishStart(_ outcome: PersistenceOutcome) -> PersistenceOutcome {
        switch outcome {
        case .saved:
            persistenceState = .saved
            startupState = .ready
            publish(.reset)
        case .failed(let failure):
            persistenceState = .failed(failure)
            startupState = .failed(failure)
            publishFailure(failure, retry: .start)
        }
        return outcome
    }

    private func saveCurrentAndPublish(retry: PersistenceRetry) async -> PersistenceOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        let outcome = await save(session)
        switch outcome {
        case .saved:
            persistenceState = .saved
            publish(.persistence)
        case .failed(let failure):
            persistenceState = .failed(failure)
            publishFailure(failure, retry: retry)
        }
        return outcome
    }

    private func save(_ candidate: ScratchSession) async -> PersistenceOutcome {
        guard generation.rawValue < UInt64.max else {
            return .failed(PersistenceFailure(operation: .save, cause: .corrupt("persistence generation exhausted")))
        }
        generation = PersistenceGeneration(rawValue: generation.rawValue + 1)
        return await writer.enqueue(candidate, generation: generation)
    }

    private func schedulePersistence() {
        let token = UUID()
        pendingEditToken = token
        pendingEditTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self, self.pendingEditToken == token else { return }
            self.pendingEditToken = nil
            _ = await self.saveCurrentAndPublish(retry: .saveCurrent)
        }
    }

    private func publishFailure(_ failure: PersistenceFailure, retry: PersistenceRetry) {
        publish(.persistence, failure: PersistenceFailureEvent(failure: failure, retry: retry))
    }

    private func publish(_ kind: WorkspaceChangeKind, failure: PersistenceFailureEvent? = nil) {
        onChange?(WorkspaceChange(snapshot: snapshot(), kind: kind, failureEvent: failure))
    }

    private func acquireTransaction() async {
        if !transactionBusy {
            transactionBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            transactionWaiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionBusy = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }

    private func outcome(from action: WorkspaceActionOutcome) -> PersistenceOutcome {
        switch action {
        case .applied(let outcome): return outcome
        case .persistenceFailed(let failure): return .failed(failure)
        case .rejected(let error): return .failed(PersistenceFailure(operation: .save, cause: .corrupt("retry rejected: \(error)")))
        }
    }

    private func outcome(from action: CloseOutcome) -> PersistenceOutcome {
        switch action {
        case .closed(_, _, let persistence): return persistence
        case .persistenceFailed(let failure): return .failed(failure)
        default: return .failed(PersistenceFailure(operation: .save, cause: .corrupt("close retry was not applied")))
        }
    }
}

@MainActor
public final class EditorBindingUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private weak var editor: (any EditorPort)?

    public init(workspace: ScratchWorkspaceUseCase, editor: any EditorPort) {
        self.workspace = workspace
        self.editor = editor
        workspace.installClosedTabBufferBridge(
            capture: { [weak editor] bufferID in editor?.recoveryCapture(for: bufferID) },
            install: { [weak editor] snapshot in editor?.installRecovery(snapshot) },
            retire: { [weak editor] bufferID in editor?.retire(bufferID: bufferID) }
        )
        editor.onEdit = { [weak workspace] edit in
            workspace?.acceptEditorEdit(edit) ?? .rejected(currentRevision: edit.expectedRevision)
        }
    }

    public func render(_ change: WorkspaceChange, requestFocus: Bool = false) {
        if case .tabRemoved(_, let bufferID) = change.kind { editor?.retire(bufferID: bufferID) }
        if case .tabUpdated = change.kind {
            editor?.setInputEnabled(change.snapshot.startup == .ready)
            if requestFocus, change.snapshot.startup == .ready { editor?.focus() }
            return
        }
        if case .bufferEdited = change.kind {
            editor?.setInputEnabled(change.snapshot.startup == .ready)
            if requestFocus, change.snapshot.startup == .ready { editor?.focus() }
            return
        }
        if case .persistence = change.kind {
            editor?.setInputEnabled(change.snapshot.startup == .ready)
            return
        }
        render(change.snapshot, requestFocus: requestFocus)
    }

    public func render(_ snapshot: WorkspaceSnapshot, requestFocus: Bool = false) {
        editor?.setInputEnabled(snapshot.startup == .ready)
        if let activeBuffer = snapshot.activeBuffer { editor?.display(activeBuffer) }
        if requestFocus, snapshot.startup == .ready { editor?.focus() }
    }

    public func activeTextSnapshot() -> EditorTextSnapshot? {
        guard let active = workspace.snapshot().activeBuffer else { return nil }
        return editor?.snapshot(for: active.bufferID)
    }
}
