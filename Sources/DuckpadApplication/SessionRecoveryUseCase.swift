import DuckpadDomain
import Foundation

/// Coordinates editor-owned text with a durable recovery store. The editor
/// supplies immutable UTF-8 checkpoints plus bounded deltas, so autosave never
/// reads or rewrites the whole native document on the keystroke path.
@MainActor
public final class SessionRecoveryUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let store: any RecoveryStore
    private let debounce: Duration
    private var generation = PersistenceGeneration(rawValue: 0)
    private var changeSerial: UInt64 = 0
    private var pendingToken: UUID?
    private var pendingTask: Task<Void, Never>?
    private var isRestoring = false
    private var recoveryOperationBusy = false
    private var recoveryOperationWaiters: [CheckedContinuation<Void, Never>] = []

    public var onFailure: (@MainActor (SessionStoreError) -> Void)?

    public init(
        workspace: ScratchWorkspaceUseCase,
        editor: any EditorPort,
        store: any RecoveryStore,
        debounce: Duration = .milliseconds(250)
    ) {
        self.workspace = workspace
        self.editor = editor
        self.store = store
        self.debounce = debounce
        workspace.installCloseRecoveryCommitter { [weak self] candidate in
            guard let self else { return .failed(.unavailable("recovery coordinator deallocated")) }
            return await self.commit(session: candidate)
        }
    }

    @discardableResult
    public func start() async -> PersistenceOutcome {
        isRestoring = true
        editor.setInputEnabled(false)
        defer { isRestoring = false }
        do {
            if let stored = try await store.loadLatest() {
                try validate(stored.archive)
                generation = stored.generation
                let result = await workspace.start(
                    restoring: StoredSession(session: stored.archive.session, generation: stored.generation)
                ) { [editor] in
                    for snapshot in stored.archive.buffers.values {
                        editor.installRecovery(snapshot)
                    }
                }
                if case .saved = result { scheduleAutosave() }
                return result
            }
            let result = await workspace.start()
            if case .saved = result { scheduleAutosave() }
            return result
        } catch let error as SessionStoreError {
            onFailure?(error)
            // A corrupt recovery root must not make the editor writable with an
            // unreviewed partial session. The normal workspace start remains a
            // deliberate fallback only when no recovery exists.
            return .failed(PersistenceFailure(operation: .load, cause: error))
        } catch {
            let failure = SessionStoreError.corrupt(String(describing: error))
            onFailure?(failure)
            return .failed(PersistenceFailure(operation: .load, cause: failure))
        }
    }

    public func workspaceDidChange(_ change: WorkspaceChange) {
        guard !isRestoring else { return }
        switch change.kind {
        case .persistence:
            return
        case .reset, .tabInserted, .activeTabChanged, .tabUpdated, .bufferEdited, .tabRemoved, .tabsReordered:
            changeSerial &+= 1
            scheduleAutosave()
        }
    }

    @discardableResult
    public func flush() async -> RecoveryOutcome {
        pendingToken = nil
        return await commit(session: workspace.recoverySession())
    }

    /// Final lifecycle barrier. Input is disabled before waiting for an older
    /// autosave, and the capture/commit repeats until no workspace change was
    /// accepted during the durable write.
    @discardableResult
    public func flushForTermination() async -> RecoveryOutcome {
        pendingToken = nil
        editor.setInputEnabled(false)
        defer { editor.setInputEnabled(workspace.snapshot().startup == .ready) }
        while true {
            let serial = changeSerial
            let outcome = await commit(session: workspace.recoverySession())
            guard case .saved = outcome else { return outcome }
            if serial == changeSerial { return outcome }
        }
    }

    private func commit(session: ScratchSession) async -> RecoveryOutcome {
        await acquireRecoveryOperation()
        defer { releaseRecoveryOperation() }
        let capturedSerial = changeSerial
        let archive: RecoveryArchive
        do { archive = try await capture(session: session) }
        catch let error as SessionStoreError {
            onFailure?(error)
            return .failed(error)
        } catch {
            let failure = SessionStoreError.corrupt(String(describing: error))
            onFailure?(failure)
            return .failed(failure)
        }
        guard generation.rawValue < UInt64.max else {
            let failure = SessionStoreError.corrupt("recovery generation exhausted")
            onFailure?(failure)
            return .failed(failure)
        }
        let next = PersistenceGeneration(rawValue: generation.rawValue + 1)
        do {
            let result = try await store.commit(archive, generation: next)
            switch result {
            case .committed:
                generation = next
            case .superseded(let durable):
                generation = max(generation, durable)
            }
            for snapshot in archive.buffers.values {
                editor.acknowledgeRecoverySnapshot(snapshot)
            }
            if changeSerial != capturedSerial { scheduleAutosave() }
            return .saved(generation)
        } catch let error {
            onFailure?(error)
            if changeSerial != capturedSerial { scheduleAutosave() }
            return .failed(error)
        }
    }

    public func waitForPendingAutosave() async {
        await pendingTask?.value
    }

    @discardableResult
    public func reset() async -> RecoveryOutcome {
        pendingToken = nil
        await acquireRecoveryOperation()
        defer { releaseRecoveryOperation() }
        do {
            try await store.reset()
            generation = PersistenceGeneration(rawValue: 0)
            return .saved(generation)
        } catch let error {
            onFailure?(error)
            return .failed(error)
        }
    }

    /// Explicit user retry boundary for a root whose every generation failed
    /// validation. No partial archive becomes editable.
    public func discardFailedRecoveryAndStart() async -> PersistenceOutcome {
        switch await reset() {
        case .saved:
            return await start()
        case .failed(let error):
            return .failed(PersistenceFailure(operation: .load, cause: error))
        }
    }

    private func scheduleAutosave() {
        let token = UUID()
        pendingToken = token
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard pendingToken == token else { return }
            pendingToken = nil
            _ = await flush()
        }
    }

    private func capture(session: ScratchSession) async throws -> RecoveryArchive {
        var captures: [BufferID: EditorRecoveryCapture] = [:]
        for metadata in session.buffers.values {
            if let capture = editor.recoveryCapture(for: metadata.id) {
                guard capture.revision == metadata.revision else {
                    throw SessionStoreError.corrupt("editor/session revision mismatch for \(metadata.id.rawValue)")
                }
                captures[metadata.id] = capture
            } else if metadata.revision == 0 {
                captures[metadata.id] = EditorRecoveryCapture(
                    bufferID: metadata.id,
                    baseRevision: 0,
                    revision: 0,
                    baseUTF8: Data()
                )
            } else {
                throw SessionStoreError.corrupt("missing editor recovery buffer \(metadata.id.rawValue)")
            }
        }
        let buffers = try await Task.detached(priority: .utility) {
            var materialized: [BufferID: EditorRecoverySnapshot] = [:]
            for (id, capture) in captures {
                materialized[id] = try capture.materializedSnapshot()
            }
            return materialized
        }.value
        return RecoveryArchive(session: session, buffers: buffers)
    }

    private func acquireRecoveryOperation() async {
        if !recoveryOperationBusy {
            recoveryOperationBusy = true
            return
        }
        await withCheckedContinuation { recoveryOperationWaiters.append($0) }
    }

    private func releaseRecoveryOperation() {
        if recoveryOperationWaiters.isEmpty {
            recoveryOperationBusy = false
        } else {
            recoveryOperationWaiters.removeFirst().resume()
        }
    }

    private func validate(_ archive: RecoveryArchive) throws {
        guard Set(archive.buffers.keys) == Set(archive.session.buffers.keys) else {
            throw SessionStoreError.corrupt("recovery buffer set mismatch")
        }
        for (id, metadata) in archive.session.buffers {
            guard let snapshot = archive.buffers[id], snapshot.bufferID == id,
                  snapshot.revision == metadata.revision,
                  String(data: snapshot.utf8, encoding: .utf8) != nil else {
                throw SessionStoreError.corrupt("invalid recovery buffer \(id.rawValue)")
            }
        }
    }
}
