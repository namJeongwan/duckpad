import DuckpadDomain
import Foundation

public struct TabSnapshot: Equatable, Sendable {
    public let id: TabID
    public let title: String
    public let isActive: Bool
    public let isDirty: Bool
    public let isPinned: Bool
    public let buffer: EditorBufferDescriptor

    public init(id: TabID, title: String, isActive: Bool, isDirty: Bool, isPinned: Bool, buffer: EditorBufferDescriptor) {
        self.id = id
        self.title = title
        self.isActive = isActive
        self.isDirty = isDirty
        self.isPinned = isPinned
        self.buffer = buffer
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
    case close(TabID, CloseDecision?)
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
    case tabRemoved(index: Int, retiredBufferID: BufferID)
    case persistence
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
    case closed(activeTabID: TabID, replacementCreated: Bool, persistence: PersistenceOutcome)
    case rejected(SessionError)
    case persistenceFailed(PersistenceFailure)
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
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []

    public var onChange: ((WorkspaceChange) -> Void)?

    public init(store: any SessionStore) {
        self.store = store
        writer = OrderedSessionWriter(store: store)
        var initial = ScratchSession()
        initial.addUntitled()
        session = initial
    }

    @discardableResult
    public func start() async -> PersistenceOutcome {
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
            if let stored = try await store.loadSession() {
                generation = stored.generation
                var loaded = stored.session
                let needsSave = loaded.tabs.isEmpty
                if needsSave { loaded.addUntitled() }
                session = loaded
                if needsSave { return finishStart(await save(loaded)) }
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
        case .close(let id, let decision):
            return outcome(from: await close(tabID: id, decision: decision))
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
        var candidate = session
        let previous = candidate.tabs.firstIndex { $0.id == candidate.activeTabID }
        do {
            try candidate.activate(tabID: tabID)
            let current = candidate.tabs.firstIndex { $0.id == tabID }!
            return await persistMutation(candidate, kind: .activeTabChanged(previousIndex: previous, currentIndex: current), retry: .activate(tabID))
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
    }

    public func close(tabID: TabID, decision: CloseDecision? = nil) async -> CloseOutcome {
        await acquireTransaction()
        defer { releaseTransaction() }
        guard let removedIndex = session.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .rejected(.unknownTab(tabID))
        }
        let buffer: BufferMetadata
        do { buffer = try session.buffer(for: tabID) }
        catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }

        if buffer.isDirty {
            switch decision {
            case nil: return .requiresDecision(saveAvailable: false)
            case .cancel: return .cancelled
            case .save: return .saveUnavailable
            case .discard: break
            }
        }

        var candidate = session
        do {
            _ = try candidate.close(tabID: tabID, discardingDirty: buffer.isDirty && decision == .discard)
            let replacementCreated = candidate.tabs.isEmpty
            if replacementCreated { candidate.addUntitled() }
            switch await save(candidate) {
            case .saved:
                session = candidate
                persistenceState = .saved
                publish(.tabRemoved(index: removedIndex, retiredBufferID: buffer.id))
                return .closed(activeTabID: candidate.activeTabID!, replacementCreated: replacementCreated, persistence: .saved)
            case .failed(let failure):
                persistenceState = .failed(failure)
                publishFailure(failure, retry: .close(tabID, decision))
                return .persistenceFailed(failure)
            }
        } catch let error as SessionError { return .rejected(error) }
        catch { preconditionFailure("ScratchSession only throws SessionError") }
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
            publish(.tabUpdated(index: index))
            return .accepted(newRevision: revision)
        } catch {
            let current = (try? session.buffer(for: tabID).revision) ?? edit.expectedRevision
            return .rejected(currentRevision: current)
        }
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
            return TabSnapshot(id: tab.id, title: document.title, isActive: tab.id == session.activeTabID, isDirty: buffer.isDirty, isPinned: tab.isPinned, buffer: EditorBufferDescriptor(bufferID: buffer.id, revision: buffer.revision))
        }
        return WorkspaceSnapshot(sessionID: session.id, tabs: tabs, activeBuffer: tabs.first(where: \.isActive)?.buffer, persistence: persistenceState, startup: startupState)
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
        editor.onEdit = { [weak workspace] edit in
            workspace?.acceptEditorEdit(edit) ?? .rejected(currentRevision: edit.expectedRevision)
        }
    }

    public func render(_ change: WorkspaceChange, requestFocus: Bool = false) {
        if case .tabRemoved(_, let bufferID) = change.kind { editor?.retire(bufferID: bufferID) }
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
