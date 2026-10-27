import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import DuckpadScintillaBridge
import Foundation
import Testing

private struct RemoteFixtureReader: FileObservationReading {
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        guard case .ssh(let location) = source else { throw FileObservationError.invalidResponse }
        return try await LocalFileObservationReader().read(.local(location.path), after: cursor, maximumBytes: maximumBytes)
    }
}

private actor ObservationBlockingStore: SessionStore {
    private var stored: StoredSession?
    private var block = false, entered = false, released = false
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if block {
            block = false; entered = true
            while !released { await Task.yield() }
        }
        stored = .init(session: session, generation: generation)
        return .committed
    }
    func arm() { block = true; entered = false; released = false }
    func waitEntered() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
    }
    func release() { released = true }
}

@Suite(.serialized) @MainActor struct TailRemoteIntegrationTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }
    @Test func localTailKeepsDirtyUndoRecoveryAndSharedSelectionsConsistent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.log")
        let original = String(repeating: "before\n", count: 300)
        try Data(original.utf8).write(to: file)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json")))
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: LocalFileObservationReader(), interval: .milliseconds(10))
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            editorAdapter: editor, editorView: editor.view, fileUseCase: files, tailFileUseCase: tail)
        defer { tail.cancelAll(); controller.close(); editor.invalidate() }
        await controller.waitForStartup()
        guard case .opened(let tab) = await files.open(file) else { Issue.record("Open failed"); return }
        try await tail.start(tabID: tab)
        let view = try #require(editor.activeScintillaView)
        #expect(!view.isInputEnabled)
        let snapshots = view.snapshotReadCount
        editor.split(orientation: .sideBySide)
        let clone = try #require(editor.secondaryScintillaView)
        clone.restoreCaretUTF8Position(10, anchorPosition: 2, firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: false)
        view.restoreCaretUTF8Position(10, anchorPosition: 2, firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: false)
        let append = Data("한글 🦆\n".utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        for byte in append { try handle.write(contentsOf: Data([byte])); try await Task.sleep(for: .milliseconds(5)) }
        try handle.close()
        try await wait { view.documentByteLength == original.utf8.count + append.count }
        #expect(clone.anchorUTF8Position == 2 && clone.caretUTF8Position == 10)
        #expect(clone.firstVisibleLine == 0)
        #expect(view.snapshotReadCount == snapshots)
        #expect(!view.canUndo)
        #expect(tail.unreadLineCounts[tab] == 1)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == tab })?.isDirty == false)
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(context.buffer.revision == view.revision)
        #expect(try editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(original.utf8) + append)
        #expect(await files.saveActive() == .failed(.readOnly))
        try Data("rotated\n".utf8).write(to: file, options: .atomic)
        try await wait { view.documentByteLength == 8 }
        #expect(view.contentUTF8 == Data("rotated\n".utf8))
        #expect(tail.unreadLineCounts[tab] == nil)
        controller.performStopTailMode()
        try await wait { workspace.fileContext(tabID: tab)?.binding?.tailMode != true }
        #expect(view.isInputEnabled)
        let before = view.documentByteLength
        files.suspendLiveReload()
        try Data("stopped after cancel\n".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(80))
        #expect(view.documentByteLength == before)
    }

    @Test func appendBeforeReflowPaintRetainsFollowIntent() throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let id = BufferID(), source = String(repeating: "long wrapped log message\n", count: 300)
        editor.install(.init(bufferID: id, revision: 0, text: source))
        editor.display(.init(bufferID: id, revision: 0))
        let view = try #require(editor.activeScintillaView)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        editor.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        editor.followObservedFileEnd(in: id)
        // A group restoration/rewrap can temporarily move the viewport while
        // retaining the end selection. Append synchronously, before a paint.
        view.restoreCaretUTF8Position(UInt(source.utf8.count), anchorPosition: UInt(source.utf8.count), firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: true)
        #expect(view.isObservedFileFollowingEnd)
        #expect(editor.applyObservedUTF8(Data("new\n".utf8), to: .init(bufferID: id, revision: 1), reset: false))
        #expect(view.caretUTF8Position == source.utf8.count + 4)
        #expect(view.isObservedFileFollowingEnd)
    }

    @Test func twoRemoteLogsKeepFollowingAcrossSplitAndFocusChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let reader = RemoteFixtureReader()
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader)
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, secondaryEditorView: editor.secondaryGroupView, editorGroupRouter: editor, remoteFileUseCase: remote, tailFileUseCase: tail)
        defer { tail.cancelAll(); controller.close(); editor.invalidate() }
        await controller.waitForStartup()
        controller.showAndFocus()
        let initial = String(repeating: "long log message " + String(repeating: "value ", count: 25) + "\n", count: 300)
        var tabs: [TabID] = [], buffers: [BufferID] = [], files: [URL] = [], views: [DPScintillaEditorView] = []
        for name in ["first.log", "second.log"] {
            let file = root.appendingPathComponent(name)
            try Data(initial.utf8).write(to: file)
            files.append(file)
            let location = try #require(RemoteFileLocation(host: "test-alias", path: file.path))
            let tab = try await remote.open(location, tail: true)
            tabs.append(tab)
            buffers.append(try #require(workspace.fileContext(tabID: tab)).buffer.bufferID)
            views.append(try #require(editor.activeScintillaView))
            try await tail.start(tabID: tab)
            editor.setWordWrapEnabled(true)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
            editor.followObservedFileEnd(in: buffers.last!)
            #expect(editor.isObservedFileFollowingEnd(in: buffers.last!))
        }
        controller.performMoveActiveTabToGroupRight(nil)
        try await wait { controller.editorGroupLayoutSnapshot.visibleGroups.count == 2 }
        controller.window?.contentView?.layoutSubtreeIfNeeded(); controller.window?.displayIfNeeded()
        for buffer in buffers { #expect(editor.isObservedFileFollowingEnd(in: buffer)) }
        #expect(controller.editorGroupLayoutSnapshot.visibleGroups.count == 2)
        for step in 1...3 {
            for index in 0..<2 {
                _ = await workspace.activate(tabID: tabs[index])
                let handle = try FileHandle(forWritingTo: files[index])
                try handle.seekToEnd(); try handle.write(contentsOf: Data("한글 \(step)\n".utf8)); try handle.close()
            }
            try await wait { buffers.allSatisfy { editor.observedByteCount(for: $0) == initial.utf8.count + step * 9 } }
            for buffer in buffers { #expect(editor.isObservedFileFollowingEnd(in: buffer)) }
            for tab in tabs { #expect(tail.states[tab] == .following) }
        }
        // One pane deliberately pauses; new bytes still arrive without moving
        // its selection/viewport, while the other pane continues following.
        views[0].restoreCaretUTF8Position(10, anchorPosition: 2, firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: true)
        #expect(!editor.isObservedFileFollowingEnd(in: buffers[0]))
        for file in files {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("last\n".utf8)); try handle.close()
        }
        try await wait { buffers.allSatisfy { editor.observedByteCount(for: $0) == initial.utf8.count + 32 } }
        #expect(views[0].anchorUTF8Position == 2 && views[0].caretUTF8Position == 10 && views[0].firstVisibleLine == 0)
        #expect(editor.isObservedFileFollowingEnd(in: buffers[1]))
        for buffer in buffers {
            #expect(editor.snapshot(for: buffer)?.text == initial + "한글 1\n한글 2\n한글 3\nlast\n")
        }
    }

    @Test func stoppingUnchangedTailUnlocksOnlyAValidatedLocalSnapshot() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("base\n".utf8).write(to: file)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: LocalFileObservationReader())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            editorAdapter: editor, editorView: editor.view, fileUseCase: files, tailFileUseCase: tail)
        defer { tail.cancelAll(); controller.close(); editor.invalidate() }
        await controller.waitForStartup()
        guard case .opened(let tab) = await files.open(file) else { Issue.record("Open failed"); return }
        try await tail.start(tabID: tab)
        controller.performStopTailMode()
        try await wait { workspace.fileContext(tabID: tab)?.binding?.tailMode != true }
        #expect(editor.activeScintillaView?.isInputEnabled == true)
        try await tail.start(tabID: tab)
        tail.cancel(tab)
        try (Data("base\n".utf8) + Data([0xED])).write(to: file)
        await files.refreshFromDisk(tabID: tab)
        #expect(workspace.fileContext(tabID: tab)?.binding?.tailMode == true)
        #expect(workspace.fileContext(tabID: tab)?.binding?.binaryByteCount == nil)
        #expect(editor.activeScintillaView?.contentUTF8 == Data("base\n".utf8))
    }

    @Test(arguments: [true, false]) func largeRemoteCompletionPreservesNavigationAndFinishesCommittedSnapshot(cancel: Bool) async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data(String(repeating: "remote 한글\n", count: 700_000).utf8)
        try bytes.write(to: file)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        defer { editor.invalidate() }
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: RemoteFixtureReader())
        let location = try #require(RemoteFileLocation(host: "test-alias", path: file.path))
        let open = Task { try await remote.open(location) }
        try await wait {
            guard let tab = workspace.tabID(canonicalPath: location.identifier), let context = workspace.fileContext(tabID: tab) else { return false }
            return editor.hasPendingTextLoad(for: context.buffer.bufferID)
        }
        let remoteView = try #require(editor.activeScintillaView)
        let scratch = try #require(workspace.snapshot().tabs.first(where: { $0.fullPath == nil }))
        _ = await workspace.activate(tabID: scratch.id)
        let scratchView = try #require(editor.activeScintillaView)
        if cancel { open.cancel() }
        do { _ = try await open.value; #expect(!cancel) } catch { #expect(cancel) }
        #expect(workspace.snapshot().activeBuffer == scratch.buffer)
        #expect(editor.activeScintillaView === scratchView)
        let tab = try #require(workspace.tabID(canonicalPath: location.identifier))
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(!editor.hasPendingTextLoad(for: context.buffer.bufferID))
        #expect(remoteView.documentByteLength == UInt(bytes.count))
        #expect(!remoteView.isInputEnabled)
        #expect(try await remote.open(location) == tab)
        #expect(editor.snapshot(for: context.buffer.bufferID)?.text.utf8.count == bytes.count)
    }

    @Test func terminationWaitsForAcceptedRemoteSnapshotCompletion() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data(String(repeating: "remote 한글\n", count: 700_000).utf8)
        try bytes.write(to: file)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: RemoteFixtureReader())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            editorAdapter: editor, editorView: editor.view, remoteFileUseCase: remote)
        defer { controller.close(); editor.invalidate() }
        await controller.waitForStartup()
        let location = try #require(RemoteFileLocation(host: "test-alias", path: file.path))
        let open = Task { try await controller.openRemoteFiles([location], follow: false) }
        try await wait {
            guard let tab = workspace.tabID(canonicalPath: location.identifier), let context = workspace.fileContext(tabID: tab) else { return false }
            return editor.hasPendingTextLoad(for: context.buffer.bufferID)
        }
        #expect(controller.beginTerminationReviewAdmission())
        open.cancel()
        _ = await controller.prepareTerminationDocuments()
        let tab = try #require(workspace.tabID(canonicalPath: location.identifier))
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(!editor.hasPendingTextLoad(for: context.buffer.bufferID))
        #expect(editor.snapshot(for: context.buffer.bufferID)?.text.utf8.count == bytes.count)
        _ = await open.result
    }

    @Test func tailStartRejectsTypingAndCancellationWhileWaitingForPersistence() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("base".utf8).write(to: file)
        let store = ObservationBlockingStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        defer { editor.invalidate() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        guard case .opened(let tab) = await files.open(file) else { Issue.record("Open failed"); return }
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: LocalFileObservationReader())
        defer { tail.cancelAll() }
        let context = try #require(workspace.fileContext(tabID: tab))
        await store.arm()
        workspace.fileFormatSavePointReached(context.buffer)
        await store.waitEntered()
        let start = Task { try await tail.start(tabID: tab) }
        for _ in 0..<30 { await Task.yield() }
        #expect(workspace.acceptEditorEdit(.init(bufferID: context.buffer.bufferID, expectedRevision: context.buffer.revision,
            range: .init(location: 0, length: 0), replacement: "typed")) == .accepted(newRevision: context.buffer.revision + 1))
        await store.release()
        do { try await start.value; Issue.record("Dirty Tail start succeeded") }
        catch { #expect(error as? FileObservationError == .dirtyDocument) }
        #expect(workspace.fileContext(tabID: tab)?.binding?.tailMode != true)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == tab })?.isDirty == true)
        let current = try #require(workspace.fileContext(tabID: tab))
        workspace.fileFormatSavePointReached(current.buffer)
        await workspace.waitForPendingPersistence()
        await store.arm()
        let flush = Task { await workspace.flushPersistence() }
        await store.waitEntered()
        let cancelled = Task { try await tail.start(tabID: tab) }
        for _ in 0..<30 { await Task.yield() }
        cancelled.cancel(); tail.cancel(tab)
        await store.release(); _ = await flush.value
        do { try await cancelled.value; Issue.record("Cancelled Tail start succeeded") } catch { }
        #expect(workspace.fileContext(tabID: tab)?.binding?.tailMode != true)
    }

    @Test func cancelledRemoteOpenCannotPublishAfterTransactionWait() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("remote".utf8).write(to: file)
        let store = ObservationBlockingStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        let editor = ScintillaEditorAdapter()
        _ = await workspace.start()
        defer { editor.invalidate() }
        let original = workspace.snapshot()
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: RemoteFixtureReader())
        await store.arm()
        let flush = Task { await workspace.flushPersistence() }
        await store.waitEntered()
        let open = Task { try await remote.open(RemoteFileLocation(host: "test-alias", path: file.path)!) }
        try await Task.sleep(for: .milliseconds(50))
        open.cancel()
        await store.release(); _ = await flush.value
        do { _ = try await open.value; Issue.record("Cancelled remote open succeeded") } catch { }
        #expect(workspace.snapshot().tabs == original.tabs)
        #expect(workspace.snapshot().activeBuffer == original.activeBuffer)
    }

    @Test func remoteSnapshotTailAndRestartUseObservedOffsetWithoutDuplicatingBytes() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("start\n".utf8).write(to: file)
        let location = try #require(RemoteFileLocation(host: "test-alias", path: file.path))
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        defer { editor.invalidate() }
        let remote = RemoteFileUseCase(workspace: workspace, editor: editor, reader: RemoteFixtureReader())
        let tab = try await remote.open(location)
        #expect(try await remote.open(location) == tab)
        let view = try #require(editor.activeScintillaView)
        #expect(view.contentUTF8 == Data("start\n".utf8)); #expect(!view.isInputEnabled)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: RemoteFixtureReader(), interval: .milliseconds(5))
        defer { tail.cancelAll() }
        try await tail.start(tabID: tab)
        let fileHandle = try FileHandle(forWritingTo: file)
        try fileHandle.seekToEnd(); try fileHandle.write(contentsOf: Data("한글\n".utf8)); try fileHandle.close()
        try await wait { view.documentByteLength == 13 }
        tail.cancel(tab)
        try await tail.start(tabID: tab)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.contentUTF8 == Data("start\n한글\n".utf8))
        try await tail.clear(tabID: tab)
        #expect(view.contentUTF8.isEmpty)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == tab })?.isDirty == false)
        tail.cancel(tab)
        _ = await workspace.close(tabID: tab, decision: .discard)
        tail.reconcileTabs()
        #expect(tail.states.isEmpty)
    }
}
