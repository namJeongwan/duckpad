import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

private actor RemoteAdmissionStore: SessionStore {
    var stored: StoredSession?
    var fail = false
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if fail { fail = false; throw .unavailable("fixture") }
        stored = .init(session: session, generation: generation)
        return .committed
    }
    func failNextCommit() { fail = true }
}

private struct RemoteAdmissionReader: FileObservationReading {
    let bytes = Data(String(repeating: "line\n", count: 1_700_000).utf8)
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        let offset = Int(cursor?.offset ?? 0), end = min(bytes.count, offset + maximumBytes)
        return .init(data: bytes.subdata(in: offset..<end), cursor: .init(identity: "1:2", offset: UInt64(end)), sourceSize: UInt64(bytes.count), reset: false)
    }
}

@MainActor private final class RemoteAdmissionEditor: ProgressiveTextEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var snapshots: [BufferID: EditorTextSnapshot] = [:]
    var pending = Set<BufferID>()
    var retired = Set<BufferID>()
    var failFinish = false
    var finishCount = 0
    var onPrepare: (() async -> Void)?
    var onFinishFailure: (() async -> Void)?
    func display(_ buffer: EditorBufferDescriptor) { }
    func install(_ snapshot: EditorTextSnapshot) { snapshots[snapshot.bufferID] = snapshot; pending.remove(snapshot.bufferID) }
    func snapshot(for id: BufferID) -> EditorTextSnapshot? { snapshots[id] }
    func retire(bufferID: BufferID) { retired.insert(bufferID); snapshots.removeValue(forKey: bufferID); pending.remove(bufferID) }
    func setInputEnabled(_ enabled: Bool) { }
    func focus() { }
    func prepareText(_ text: String) async throws -> @MainActor (EditorBufferDescriptor) -> Void {
        await onPrepare?()
        return { buffer in
            self.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: text))
            self.pending.insert(buffer.bufferID)
        }
    }
    func hasPendingTextLoad(for id: BufferID) -> Bool { pending.contains(id) }
    func finishTextLoad(for buffer: EditorBufferDescriptor, progress: @escaping @MainActor (Int, Int) -> Void) async throws {
        finishCount += 1
        guard pending.contains(buffer.bufferID) else { throw CancellationError() }
        if failFinish { await onFinishFailure?(); throw FileObservationError.unavailable }
        pending.remove(buffer.bufferID)
    }
}

@Suite(.serialized) @MainActor struct RemoteFileAdmissionTests {
    @Test(arguments: [false, true]) func failedCloseRetainsRecoveryAndReopenRetriesOwnedNativeLoad(restore: Bool) async throws {
        let store = RemoteAdmissionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        _ = await workspace.start()
        let editor = RemoteAdmissionEditor(), reader = RemoteAdmissionReader()
        editor.failFinish = true
        editor.onFinishFailure = { await store.failNextCommit() }
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader)
        let location = try #require(RemoteFileLocation(host: "fixture", path: "/tmp/app.log"))
        do { _ = try await remote.open(location); Issue.record("Native failure was ignored") }
        catch { #expect(error as? FileObservationError == .unavailable) }
        let tab = try #require(workspace.tabID(canonicalPath: location.identifier))
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(!editor.retired.contains(context.buffer.bufferID))
        #expect(editor.recoverySnapshot(for: context.buffer.bufferID)?.utf8.count == reader.bytes.count)
        #expect(editor.hasPendingTextLoad(for: context.buffer.bufferID))
        if restore {
            workspace.installClosedTabBufferBridge(capture: { editor.recoveryCapture(for: $0) },
                install: { editor.installRecovery($0) }, retire: { editor.retire(bufferID: $0) })
            guard case .closed = await workspace.close(tabID: tab, decision: .discard) else { Issue.record("Close failed"); return }
            #expect(await workspace.restoreLastClosedTab() == .applied(.saved))
            #expect(!editor.hasPendingTextLoad(for: context.buffer.bufferID))
        }
        editor.failFinish = false
        #expect(try await remote.open(location) == tab)
        #expect(!editor.hasPendingTextLoad(for: context.buffer.bufferID))
        #expect(editor.finishCount == (restore ? 1 : 2))
    }

    @Test func tabCreatedDuringPreparationIsReusedWithoutLoadingOrClosingIt() async throws {
        let workspace = ScratchWorkspaceUseCase(store: RemoteAdmissionStore())
        _ = await workspace.start()
        let editor = RemoteAdmissionEditor()
        let location = try #require(RemoteFileLocation(host: "fixture", path: "/tmp/app.log"))
        var existing: TabID?
        editor.onPrepare = {
            let identity = FileIdentity(canonicalPath: location.identifier, device: 1, inode: 2, byteCount: 7, modifiedNanoseconds: 0, contentToken: "1:2")
            let binding = FileBinding(canonicalPath: location.identifier, encoding: .utf8, byteOrderMark: .absent,
                lineEnding: .lf, observedIdentity: identity, remoteFile: location)
            existing = await workspace.addObservedFile(binding: binding, title: location.title, isCurrent: { true }, install: { buffer in
                editor.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: "already"))
            })
        }
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: RemoteAdmissionReader())
        let tab = try await remote.open(location)
        #expect(tab == existing)
        #expect(editor.finishCount == 0 && editor.retired.isEmpty)
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(editor.snapshot(for: context.buffer.bufferID)?.text == "already")
    }
}
