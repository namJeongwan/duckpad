import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Foundation
import Testing

private actor RoutingSessionStore: SessionStore {
    private var stored: StoredSession?
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        stored = StoredSession(session: session, generation: generation)
        return .committed
    }
}

private actor BlockingNewScratchSessionStore: SessionStore {
    private var stored: StoredSession?
    private var generation = PersistenceGeneration(rawValue: 0)
    private var blockNextCommit = false
    private var blockedCommitEntered = false
    private var releaseBlockedCommit = false

    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        if blockNextCommit {
            blockNextCommit = false
            blockedCommitEntered = true
            while !releaseBlockedCommit { await Task.yield() }
        }
        guard generation > self.generation else {
            return .superseded(durableGeneration: self.generation)
        }
        stored = StoredSession(session: session, generation: generation)
        self.generation = generation
        return .committed
    }

    func armNextCommit() {
        blockNextCommit = true
        blockedCommitEntered = false
        releaseBlockedCommit = false
    }

    func waitUntilCommitIsBlocked() async {
        while !blockedCommitEntered { await Task.yield() }
    }

    func releaseCommit() { releaseBlockedCommit = true }
}

private actor DelayedStartupSessionStore: SessionStore {
    private var loadEntered = false
    private var loadReleased = false
    private var stored: StoredSession?

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        loadEntered = true
        while !loadReleased { await Task.yield() }
        return stored
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        stored = StoredSession(session: session, generation: generation)
        return .committed
    }

    func waitUntilLoadEntered() async {
        while !loadEntered { await Task.yield() }
    }

    func releaseLoad() { loadReleased = true }
}

private actor RoutingRecoveryStore: RecoveryStore {
    private var stored: StoredRecoveryArchive?
    private var loadError: SessionStoreError?
    private(set) var commitCount = 0
    private var blockNextReset = false
    private var resetEntered = false
    private var releaseReset = false
    func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? {
        if let loadError { throw loadError }
        return stored
    }
    func commit(_ archive: RecoveryArchive, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        stored = StoredRecoveryArchive(archive: archive, generation: generation)
        commitCount += 1
        return .committed
    }
    func reset() async throws(SessionStoreError) {
        if blockNextReset {
            blockNextReset = false
            resetEntered = true
            while !releaseReset { await Task.yield() }
        }
        stored = nil
    }
    func setLoadError(_ error: SessionStoreError?) { loadError = error }
    func latestTabCount() -> Int? { stored?.archive.session.tabs.count }
    func latestBookmarkedLines() -> [Int]? { stored?.archive.buffers.values.first?.viewState.bookmarkedLines }
    func armBlockedReset() { blockNextReset = true; resetEntered = false; releaseReset = false }
    func hasEnteredBlockedReset() -> Bool { resetEntered }
    func releaseBlockedReset() { releaseReset = true }
}

@MainActor
private final class SplitRecordingEditor: SplitEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var active: EditorBufferDescriptor?
    private(set) var splitOrientation: EditorSplitOrientation?
    private(set) var focusOtherCount = 0

    func display(_ buffer: EditorBufferDescriptor) {
        active = buffer
        snapshots[buffer.bufferID] = snapshots[buffer.bufferID]
            ?? EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
    }
    func install(_ snapshot: EditorTextSnapshot) { snapshots[snapshot.bufferID] = snapshot }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { snapshots[bufferID] }
    func retire(bufferID: BufferID) { snapshots.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        snapshots[bufferID].map { EditorRecoverySnapshot(bufferID: bufferID, revision: $0.revision, utf8: Data($0.text.utf8)) }
    }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        recoverySnapshot(for: bufferID).map {
            EditorRecoveryCapture(bufferID: bufferID, baseRevision: $0.revision, revision: $0.revision, baseUTF8: $0.utf8, deltas: [], viewState: $0.viewState)
        }
    }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {
        snapshots[snapshot.bufferID] = EditorTextSnapshot(
            bufferID: snapshot.bufferID,
            revision: snapshot.revision,
            text: String(decoding: snapshot.utf8, as: UTF8.self)
        )
    }
    func split(orientation: EditorSplitOrientation) { splitOrientation = orientation }
    func closeSplit() { splitOrientation = nil }
    func focusOtherPane() { focusOtherCount += 1 }
}

@Test @MainActor func controllerRoutesSplitCommandsAndValidationToCapableEditor() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = SplitRecordingEditor()
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: NSView(frame: .zero),
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let splitDown = NSMenuItem(title: "Split", action: #selector(DuckpadWindowController.performSplitEditorDown(_:)), keyEquivalent: "")
    let closeSplit = NSMenuItem(title: "Close", action: #selector(DuckpadWindowController.performCloseEditorSplit(_:)), keyEquivalent: "")
    let focusOther = NSMenuItem(title: "Focus", action: #selector(DuckpadWindowController.performFocusOtherEditorPane(_:)), keyEquivalent: "")

    #expect(controller.validateMenuItem(splitDown))
    #expect(!controller.validateMenuItem(closeSplit))
    controller.performSplitEditorDown()
    #expect(editor.splitOrientation == .stacked)
    #expect(controller.validateMenuItem(closeSplit))
    controller.performFocusOtherEditorPane()
    #expect(editor.focusOtherCount == 1)
    controller.performCloseEditorSplit()
    #expect(editor.splitOrientation == nil)
    #expect(!controller.validateMenuItem(focusOther))
}

@Test @MainActor func controllerBookmarkCommandsPersistViewStateWithoutDirtyingDocument() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace, editor: editor, store: recoveryStore, debounce: .seconds(60)
    )
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        recoveryUseCase: recovery,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let descriptor = workspace.snapshot().activeBuffer!
    editor.install(.init(bufferID: descriptor.bufferID, revision: descriptor.revision, text: "zero\none"))
    editor.textView.setSelectedRange(NSRange(location: 5, length: 0))

    controller.performToggleBookmark()
    #expect(await controller.flushRecovery())
    #expect(await recoveryStore.latestBookmarkedLines() == [1])
    #expect(workspace.snapshot().activeBuffer?.revision == 0)
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == false)
    #expect(editor.textView.undoManager?.canUndo == false)

    controller.performClearBookmarks()
    #expect(await controller.flushRecovery())
    #expect(await recoveryStore.latestBookmarkedLines() == [])
}

@MainActor
private final class RecoveryErrorPresenterSpy: PersistenceErrorPresenting {
    private(set) var failures: [PersistenceFailure] = []
    private var retryAction: (@MainActor () -> Void)?
    func present(failure: PersistenceFailure, retry: @escaping @MainActor () -> Void) {
        failures.append(failure)
        retryAction = retry
    }
    func retry() { retryAction?() }
}

private actor RoutingFileStore: TextFileStore {
    private var values: [String: FileReadResult] = [:]
    private var generation: UInt64 = 0
    private var forcedWriteError: TextFileStoreError?
    private var blockNextRead = false
    private var blockedReadEntered = false
    private var releaseBlockedRead = false
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { url.standardizedFileURL }
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        if blockNextRead {
            blockNextRead = false
            blockedReadEntered = true
            while !releaseBlockedRead { await Task.yield() }
        }
        guard let value = values[url.path] else { throw .notFound(url.path) }
        return value
    }
    func writeAtomically(_ data: Data, to url: URL, expectedIdentity: FileIdentity?, overwrite: Bool) async throws(TextFileStoreError) -> FileWriteReceipt {
        if let forcedWriteError { throw forcedWriteError }
        let current = values[url.path]
        if let expectedIdentity, current?.identity != expectedIdentity { throw .conflict(current: current?.identity) }
        generation += 1
        let identity = FileIdentity(canonicalPath: url.path, device: 1, inode: 1, byteCount: UInt64(data.count), modifiedNanoseconds: Int64(generation), contentToken: "routing-\(generation)")
        values[url.path] = FileReadResult(data: data, identity: identity)
        return FileWriteReceipt(identity: identity)
    }
    func seed(_ text: String, at url: URL) {
        generation += 1
        let data = Data(text.utf8)
        let identity = FileIdentity(canonicalPath: url.path, device: 1, inode: 1, byteCount: UInt64(data.count), modifiedNanoseconds: Int64(generation), contentToken: "routing-\(generation)")
        values[url.path] = FileReadResult(data: data, identity: identity)
    }
    func text(at url: URL) -> String? { values[url.path].flatMap { String(data: $0.data, encoding: .utf8) } }
    func result(at url: URL) -> FileReadResult? { values[url.path] }
    func setWriteError(_ error: TextFileStoreError?) { forcedWriteError = error }
    func armNextRead() {
        blockNextRead = true
        blockedReadEntered = false
        releaseBlockedRead = false
    }
    func waitUntilReadIsBlocked() async {
        while !blockedReadEntered { await Task.yield() }
    }
    func releaseRead() { releaseBlockedRead = true }
}

private struct PreparedWorkspaceRootStore: WorkspaceRootStore {
    let root: WorkspaceRoot
    let entry: WorkspaceBrowserEntry
    let read: WorkspaceFileRead

    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] { [root] }
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        throw .duplicateRoot(root.canonicalPath)
    }
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) {}
    func children(
        rootID: WorkspaceRootID,
        relativeDirectory: String
    ) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] { [entry] }
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead { read }
    func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { root }
}

private struct RoutingFolderStore: FolderSearchFileStore {
    let enumeration: FolderSearchEnumeration

    func enumerateTextCandidates(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int
    ) async throws(FolderSearchFailure) -> FolderSearchEnumeration {
        enumeration
    }
}

@MainActor
private final class PanelFake: FilePanelPresenting, FileConflictPresenting, DirtyDocumentDecisionPresenting {
    var openURL: URL?
    var saveURL: URL?
    var folderURL: URL?
    private(set) var openRequests = 0
    private(set) var saveRequests = 0
    private(set) var folderRequests = 0
    private(set) var failures: [FileOperationFailure] = []
    private(set) var fileFailureRetries: [@MainActor () -> Void] = []
    var conflictResolutions: [FileConflictResolution] = []
    private(set) var comparisons: [ExternalFileComparison] = []
    var decisions: [CloseDecision] = []
    var blocksDecisions = false
    private(set) var decisionTabs: [String] = []
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { openRequests += 1; return openURL }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? { saveRequests += 1; return saveURL }
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? { folderRequests += 1; return folderURL }
    func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution {
        conflictResolutions.isEmpty ? .cancel : conflictResolutions.removeFirst()
    }
    func presentExternalComparison(_ comparison: ExternalFileComparison, attachedTo window: NSWindow?) async {
        comparisons.append(comparison)
    }
    func presentFileFailure(
        _ failure: FileOperationFailure,
        attachedTo window: NSWindow?,
        retry: @escaping @MainActor () -> Void
    ) {
        failures.append(failure)
        fileFailureRetries.append(retry)
    }
    func retryLastFileFailure() { fileFailureRetries.last?() }
    func decision(for tab: TabSnapshot, saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision {
        decisionTabs.append(tab.title)
        if blocksDecisions {
            await withCheckedContinuation { decisionWaiters.append($0) }
        }
        return decisions.isEmpty ? .cancel : decisions.removeFirst()
    }
    func releaseDecisions() {
        blocksDecisions = false
        let waiters = decisionWaiters
        decisionWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private func descendant<T: NSView>(of type: T.Type, in root: NSView, identifier: String) -> T? {
    if let match = root as? T, match.accessibilityIdentifier() == identifier { return match }
    for child in root.subviews {
        if let match = descendant(of: type, in: child, identifier: identifier) { return match }
    }
    return nil
}

@Test @MainActor func routedFolderSearchOpensIdentityCheckedResultAndSelectsUTF8Range() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let root = URL(fileURLWithPath: "/tmp/duckpad-folder-routing", isDirectory: true)
    let url = root.appendingPathComponent("nested/result.txt")
    await files.seed("prefix duck suffix", at: url)
    guard let read = await files.result(at: url) else {
        Issue.record("file fixture unavailable")
        return
    }
    let enumeration = FolderSearchEnumeration(
        rootPath: root.path,
        files: [FolderSearchFile(
            path: url.path,
            relativePath: "nested/result.txt",
            data: read.data,
            identity: read.identity
        )],
        isTruncated: false,
        skippedFileCount: 0,
        totalBytes: read.data.count
    )
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let folderUseCase = FolderSearchUseCase(store: RoutingFolderStore(enumeration: enumeration), regexEngine: ICURegexEngine())
    let panels = PanelFake()
    panels.folderURL = root
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: fileUseCase,
        filePanels: panels,
        fileConflictPresenter: panels,
        folderSearchUseCase: folderUseCase,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    controller.performShowFind()
    guard let content = controller.window?.contentView,
          let field = descendant(of: NSSearchField.self, in: content, identifier: "duckpad.search.find"),
          let table = descendant(of: NSTableView.self, in: content, identifier: "duckpad.search.results") else {
        Issue.record("search controls unavailable")
        return
    }
    field.stringValue = "duck"

    controller.performFindInFolder()
    for _ in 0..<2_000 where table.numberOfRows < 2 { await Task.yield() }
    #expect(panels.folderRequests == 1)
    #expect(table.numberOfRows == 2)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    guard let action = table.doubleAction else {
        Issue.record("result action unavailable")
        return
    }
    _ = NSApp.sendAction(action, to: table.target, from: table)
    for _ in 0..<2_000 where workspace.activeFileContext()?.binding?.canonicalPath != url.path { await Task.yield() }

    #expect(workspace.activeFileContext()?.binding?.observedIdentity == read.identity)
    #expect(editor.textView.selectedRange() == NSRange(location: 7, length: 4))
    #expect(editor.textView.string == "prefix duck suffix")
}

@Test @MainActor func commandQJoinsCancelledFolderActivationBeforeFinalRecoveryFlush() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace, editor: editor, store: recoveryStore, debounce: .seconds(60)
    )
    let coordinator = ApplicationTerminationCoordinator()
    let url = URL(fileURLWithPath: "/tmp/duckpad-blocked-folder-result.txt")
    await files.seed("duck", at: url)
    let read = await files.result(at: url)!
    let match = FolderSearchMatch(
        range: SearchUTF8Range(location: 0, length: 4), line: 1, column: 1, snippet: "duck"
    )
    let document = FolderSearchDocumentResult(
        path: url.path, relativePath: url.lastPathComponent, identity: read.identity, matches: [match]
    )
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        recoveryUseCase: recovery,
        terminationCoordinator: coordinator,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await files.armNextRead()
    controller.routeActivateFolderSearchMatch(document: document, match: match)
    await files.waitUntilReadIsBlocked()

    var terminationReply: Bool?
    #expect(coordinator.applicationShouldTerminate { terminationReply = $0 } == .terminateLater)
    for _ in 0..<20 { await Task.yield() }
    #expect(terminationReply == nil)
    #expect(await recoveryStore.commitCount == 0)

    await files.releaseRead()
    for _ in 0..<2_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(workspace.snapshot().tabs.count == 1)
    #expect(await recoveryStore.latestTabCount() == 1)
}

@Test @MainActor func redCloseAfterUserCancelJoinsFolderActivationBeforeFlush() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace, editor: editor, store: recoveryStore, debounce: .seconds(60)
    )
    let coordinator = ApplicationTerminationCoordinator()
    let url = URL(fileURLWithPath: "/tmp/duckpad-cancelled-folder-result.txt")
    await files.seed("duck", at: url)
    let read = await files.result(at: url)!
    let match = FolderSearchMatch(
        range: SearchUTF8Range(location: 0, length: 4), line: 1, column: 1, snippet: "duck"
    )
    let document = FolderSearchDocumentResult(
        path: url.path, relativePath: url.lastPathComponent, identity: read.identity, matches: [match]
    )
    var approvedClose = false
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        recoveryUseCase: recovery,
        terminationCoordinator: coordinator,
        approvedWindowClose: { _ in approvedClose = true },
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await files.armNextRead()
    controller.routeActivateFolderSearchMatch(document: document, match: match)
    await files.waitUntilReadIsBlocked()
    controller.performCloseFindPanel()

    #expect(controller.windowShouldClose(controller.window!) == false)
    for _ in 0..<20 { await Task.yield() }
    #expect(!approvedClose)
    #expect(await recoveryStore.commitCount == 0)

    await files.releaseRead()
    for _ in 0..<2_000 where !approvedClose { await Task.yield() }
    #expect(approvedClose)
    #expect(workspace.snapshot().tabs.count == 1)
    #expect(await recoveryStore.latestTabCount() == 1)
}

@Test @MainActor func immediateTerminationCannotLivelockQueuedFolderActivation() async {
    _ = NSApplication.shared
    for index in 0..<5 {
        let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
        let editor = TextViewEditorAdapter()
        let files = RoutingFileStore()
        let recoveryStore = RoutingRecoveryStore()
        let recovery = SessionRecoveryUseCase(
            workspace: workspace, editor: editor, store: recoveryStore, debounce: .seconds(60)
        )
        let coordinator = ApplicationTerminationCoordinator()
        let url = URL(fileURLWithPath: "/tmp/duckpad-fast-folder-result-\(index).txt")
        await files.seed("duck", at: url)
        let read = await files.result(at: url)!
        let match = FolderSearchMatch(
            range: SearchUTF8Range(location: 0, length: 4), line: 1, column: 1, snippet: "duck"
        )
        let document = FolderSearchDocumentResult(
            path: url.path, relativePath: url.lastPathComponent, identity: read.identity, matches: [match]
        )
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: editor,
            editorView: editor.scrollView,
            fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
            recoveryUseCase: recovery,
            terminationCoordinator: coordinator,
            automaticallyStarts: false
        )
        controller.start()
        await controller.waitForStartup()

        controller.routeActivateFolderSearchMatch(document: document, match: match)
        var terminationReply: Bool?
        #expect(coordinator.applicationShouldTerminate { terminationReply = $0 } == .terminateLater)
        for _ in 0..<2_000 where terminationReply == nil { await Task.yield() }

        #expect(terminationReply == true)
        #expect(await recoveryStore.latestTabCount() == workspace.snapshot().tabs.count)
        controller.close()
    }
}

@Test @MainActor func routedConflictCompareIsReadOnlyThenReloadsAfterSecondDecision() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let url = URL(fileURLWithPath: "/tmp/duckpad-routing-compare.txt")
    await files.seed("base", at: url)
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.openURL = url
    panels.conflictResolutions = [.compare, .reload]
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: fileUseCase,
        filePanels: panels,
        fileConflictPresenter: panels,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await controller.routeOpenFile()
    editor.textView.selectAll(nil)
    editor.textView.insertText("mine", replacementRange: editor.textView.selectedRange())
    await files.seed("external", at: url)

    await controller.routeSaveFile()

    #expect(panels.comparisons.count == 1)
    #expect(panels.comparisons.first?.localText == "mine")
    #expect(panels.comparisons.first?.externalText == "external")
    #expect(editor.textView.string == "external")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == false)
    #expect(await files.text(at: url) == "external")
}

@Test @MainActor func controllerRoutesOpenSaveAndSaveAsThroughPanelPorts() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let openedURL = URL(fileURLWithPath: "/tmp/duckpad-routing-open.txt")
    let saveAsURL = URL(fileURLWithPath: "/tmp/duckpad-routing-save-as.txt")
    await files.seed("열기🙂", at: openedURL)
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.openURL = openedURL
    panels.saveURL = saveAsURL
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: fileUseCase,
        filePanels: panels,
        fileConflictPresenter: panels,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    await controller.routeOpenFile()
    #expect(panels.openRequests == 1)
    #expect(editor.textView.string == "열기🙂")
    #expect(controller.window?.title == "duckpad-routing-open.txt — Duckpad")

    editor.textView.textStorage?.replaceCharacters(
        in: NSRange(location: (editor.textView.string as NSString).length, length: 0),
        with: "!"
    )
    #expect(controller.window?.isDocumentEdited == true)
    await controller.routeSaveFile()
    #expect(await files.text(at: openedURL) == "열기🙂!")
    #expect(controller.window?.isDocumentEdited == false)

    _ = await workspace.addScratch()
    await controller.routeSaveFile()
    #expect(panels.saveRequests == 1)
    #expect(await files.text(at: saveAsURL) == "")
    #expect(panels.failures.isEmpty)
}

@Test @MainActor func cleanApplicationTerminationWaitsForFinalRecoveryFlush() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace,
        editor: editor,
        store: recoveryStore,
        debounce: .seconds(60)
    )
    let coordinator = ApplicationTerminationCoordinator()
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        recoveryUseCase: recovery,
        terminationCoordinator: coordinator,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()

    let approved = await withCheckedContinuation { continuation in
        #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
    }
    #expect(approved)
    #expect(await recoveryStore.commitCount == 1)
    controller.close()
}

@Test @MainActor func terminationWaitsForAcceptedNewScratchBeforeFinalRecoveryFlush() async {
    _ = NSApplication.shared
    let sessionStore = BlockingNewScratchSessionStore()
    let workspace = ScratchWorkspaceUseCase(store: sessionStore)
    let editor = TextViewEditorAdapter()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace,
        editor: editor,
        store: recoveryStore,
        debounce: .seconds(60)
    )
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        recoveryUseCase: recovery,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await sessionStore.armNextCommit()

    controller.performNewScratch()
    await sessionStore.waitUntilCommitIsBlocked()
    let review = Task { @MainActor in
        await controller.reviewDirtyDocumentsForTermination()
    }
    for _ in 0..<20 { await Task.yield() }

    #expect(workspace.snapshot().tabs.count == 1)
    #expect(await recoveryStore.commitCount == 0)

    await sessionStore.releaseCommit()
    #expect(await review.value)
    #expect(workspace.snapshot().tabs.count == 2)
    #expect(await recoveryStore.latestTabCount() == 2)
}

@Test @MainActor func terminationWaitsForAcceptedWorkspaceFileOpenBeforeFinalRecoveryFlush() async {
    _ = NSApplication.shared
    let sessionStore = BlockingNewScratchSessionStore()
    let workspace = ScratchWorkspaceUseCase(store: sessionStore)
    let editor = TextViewEditorAdapter()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace,
        editor: editor,
        store: recoveryStore,
        debounce: .seconds(60)
    )
    let rootID = WorkspaceRootID()
    let root = WorkspaceRoot(id: rootID, canonicalPath: "/tmp/workspace", displayName: "workspace")
    let entry = WorkspaceBrowserEntry(
        rootID: rootID,
        relativePath: "opened.txt",
        name: "opened.txt",
        kind: .file
    )
    let url = URL(fileURLWithPath: "/tmp/workspace/opened.txt")
    let data = Data("accepted before termination".utf8)
    let identity = FileIdentity(
        canonicalPath: url.path,
        device: 1,
        inode: 2,
        byteCount: UInt64(data.count),
        modifiedNanoseconds: 3,
        contentToken: "workspace-open"
    )
    let browser = WorkspaceBrowserUseCase(store: PreparedWorkspaceRootStore(
        root: root,
        entry: entry,
        read: WorkspaceFileRead(url: url, result: FileReadResult(data: data, identity: identity))
    ))
    let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: RoutingFileStore())
    let coordinator = ApplicationTerminationCoordinator()
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: files,
        recoveryUseCase: recovery,
        terminationCoordinator: coordinator,
        workspaceBrowserUseCase: browser,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    for _ in 0..<1_000 where !browser.acceptsCommands { await Task.yield() }
    await sessionStore.armNextCommit()

    controller.routeOpenWorkspaceEntry(entry)
    await sessionStore.waitUntilCommitIsBlocked()
    var terminationReply: Bool?
    #expect(coordinator.applicationShouldTerminate { terminationReply = $0 } == .terminateLater)
    for _ in 0..<20 { await Task.yield() }

    #expect(workspace.snapshot().tabs.count == 1)
    #expect(await recoveryStore.commitCount == 0)
    #expect(terminationReply == nil)

    await sessionStore.releaseCommit()
    for _ in 0..<1_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(workspace.snapshot().tabs.count == 2)
    #expect(await recoveryStore.latestTabCount() == 2)
    #expect(editor.snapshot(for: workspace.snapshot().activeBuffer!.bufferID)?.text == "accepted before termination")
}

@Test @MainActor func corruptOnlyRecoveryIsVisibleDisabledAndResetRetryRestoresUsability() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let recoveryStore = RoutingRecoveryStore()
    await recoveryStore.setLoadError(.corrupt("no valid recovery generation"))
    let recovery = SessionRecoveryUseCase(
        workspace: workspace,
        editor: editor,
        store: recoveryStore,
        debounce: .seconds(60)
    )
    let presenter = RecoveryErrorPresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        errorPresenter: presenter,
        recoveryUseCase: recovery,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    #expect(workspace.snapshot().startup == .restoring)
    #expect(!editor.textView.isEditable)
    #expect(presenter.failures.count == 1)
    #expect(presenter.failures[0].operation == .load)

    await recoveryStore.setLoadError(nil)
    presenter.retry()
    for _ in 0..<200 where workspace.snapshot().startup != .ready {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(workspace.snapshot().startup == .ready)
    #expect(editor.textView.isEditable)
    #expect(workspace.snapshot().tabs.count == 1)
}

@Suite(.serialized)
struct FileLifecycleTests {
    @MainActor
    private func makeController(
        decisions: [CloseDecision],
        saveURL: URL? = nil,
        writeError: TextFileStoreError? = nil,
        blocksDecisions: Bool = false,
        errorPresenter: (any PersistenceErrorPresenting)? = nil,
        recoveryStore: RoutingRecoveryStore? = nil,
        terminationCoordinator: ApplicationTerminationCoordinator? = nil,
        approvedWindowClose: (@MainActor (NSWindow) -> Void)? = nil
    ) async -> (DuckpadWindowController, ScratchWorkspaceUseCase, TextViewEditorAdapter, PanelFake, RoutingFileStore) {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
        let editor = TextViewEditorAdapter()
        let files = RoutingFileStore()
        await files.setWriteError(writeError)
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
        let recoveryUseCase = recoveryStore.map {
            SessionRecoveryUseCase(
                workspace: workspace,
                editor: editor,
                store: $0,
                debounce: .seconds(60)
            )
        }
        let panels = PanelFake()
        panels.decisions = decisions
        panels.blocksDecisions = blocksDecisions
        panels.saveURL = saveURL
        let terminationCoordinator = terminationCoordinator ?? ApplicationTerminationCoordinator()
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: editor,
            editorView: editor.scrollView,
            errorPresenter: errorPresenter,
            fileUseCase: fileUseCase,
            filePanels: panels,
            fileConflictPresenter: panels,
            dirtyDecisionPresenter: panels,
            recoveryUseCase: recoveryUseCase,
            terminationCoordinator: terminationCoordinator,
            approvedWindowClose: approvedWindowClose,
            automaticallyStarts: false
        )
        controller.start()
        await controller.waitForStartup()
        return (controller, workspace, editor, panels, files)
    }

    @MainActor
    private func dirty(_ editor: TextViewEditorAdapter, with text: String) {
        editor.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: (editor.textView.string as NSString).length),
            with: text
        )
    }

    @Test @MainActor func redCloseCancelKeepsWindowAndDiscardAllowsClose() async {
        var approvedCloseCount = 0
        let closeSpy: @MainActor (NSWindow) -> Void = { _ in approvedCloseCount += 1 }
        let (cancelController, _, cancelEditor, cancelPanels, _) = await makeController(
            decisions: [.cancel],
            approvedWindowClose: closeSpy
        )
        dirty(cancelEditor, with: "dirty")
        #expect(cancelController.windowShouldClose(cancelController.window!) == false)
        for _ in 0..<200 where cancelPanels.decisionTabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cancelPanels.decisionTabs.count == 1)
        #expect(cancelController.hasDirtyDocuments)
        #expect(approvedCloseCount == 0)
        cancelController.close()

        let (discardController, _, discardEditor, discardPanels, _) = await makeController(
            decisions: [.discard],
            approvedWindowClose: closeSpy
        )
        dirty(discardEditor, with: "dirty")
        #expect(discardController.windowShouldClose(discardController.window!) == false)
        for _ in 0..<200 where approvedCloseCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(discardPanels.decisionTabs.count == 1)
        #expect(approvedCloseCount == 1)
        discardController.close()
    }

    @Test @MainActor func appTerminationSavesOrCancelsAndSaveFailureStaysOpen() async {
        let saveURL = URL(fileURLWithPath: "/tmp/duckpad-terminate-save.txt")
        let (saveController, saveWorkspace, saveEditor, _, saveFiles) = await makeController(decisions: [.save], saveURL: saveURL)
        dirty(saveEditor, with: "saved on quit")
        let saveCoordinator = saveController.terminationCoordinator!
        let saveReply = await withCheckedContinuation { continuation in
            #expect(saveCoordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(saveReply)
        #expect(saveWorkspace.snapshot().tabs[0].isDirty == false)
        #expect(await saveFiles.text(at: saveURL) == "saved on quit")
        saveController.close()

        let (cancelController, _, cancelEditor, _, _) = await makeController(decisions: [.cancel])
        cancelController.showWindow(nil)
        dirty(cancelEditor, with: "keep me")
        let cancelCoordinator = cancelController.terminationCoordinator!
        let cancelReply = await withCheckedContinuation { continuation in
            #expect(cancelCoordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!cancelReply)
        #expect(cancelController.window?.isVisible == true)
        cancelController.close()

        let failure = TextFileStoreError.io("injected save failure")
        let workspaceFailures = RecoveryErrorPresenterSpy()
        let (failureController, failureWorkspace, failureEditor, failurePanels, _) = await makeController(
            decisions: [.save],
            saveURL: URL(fileURLWithPath: "/tmp/duckpad-terminate-failure.txt"),
            writeError: failure,
            errorPresenter: workspaceFailures
        )
        failureController.showWindow(nil)
        dirty(failureEditor, with: "still dirty")
        let failureCoordinator = failureController.terminationCoordinator!
        let failureReply = await withCheckedContinuation { continuation in
            #expect(failureCoordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!failureReply)
        #expect(failureWorkspace.snapshot().tabs[0].isDirty)
        #expect(failureController.window?.isVisible == true)
        #expect(failurePanels.failures.count == 1)
        #expect(failurePanels.fileFailureRetries.count == 1)
        #expect(workspaceFailures.failures.isEmpty)
        failureController.close()
    }

    @Test @MainActor func applicationTerminationReviewsEveryWindowAndReopensAllAfterCancel() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (first, _, firstEditor, firstPanels, _) = await makeController(
            decisions: [.discard],
            terminationCoordinator: coordinator
        )
        let (second, _, secondEditor, secondPanels, _) = await makeController(
            decisions: [.cancel],
            terminationCoordinator: coordinator
        )
        defer {
            first.close()
            second.close()
        }
        dirty(firstEditor, with: "first dirty window")
        dirty(secondEditor, with: "second dirty window")
        #expect(coordinator.attachedWindowCount == 2)

        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate {
                continuation.resume(returning: $0)
            } == .terminateLater)
        }

        #expect(!approved)
        #expect(firstPanels.decisionTabs.count == 1)
        #expect(secondPanels.decisionTabs.count == 1)
        let newScratch = NSMenuItem(
            title: "New Scratch",
            action: #selector(DuckpadWindowController.performNewScratch(_:)),
            keyEquivalent: ""
        )
        #expect(first.validateMenuItem(newScratch))
        #expect(second.validateMenuItem(newScratch))
    }

    @Test @MainActor func applicationTerminationFlushesEveryApprovedWindowBeforeReply() async {
        let coordinator = ApplicationTerminationCoordinator()
        let firstRecovery = RoutingRecoveryStore()
        let secondRecovery = RoutingRecoveryStore()
        let (first, _, firstEditor, firstPanels, _) = await makeController(
            decisions: [.discard],
            recoveryStore: firstRecovery,
            terminationCoordinator: coordinator
        )
        let (second, _, secondEditor, secondPanels, _) = await makeController(
            decisions: [.discard],
            recoveryStore: secondRecovery,
            terminationCoordinator: coordinator
        )
        defer {
            first.close()
            second.close()
        }
        dirty(firstEditor, with: "first retained recovery")
        dirty(secondEditor, with: "second retained recovery")

        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate {
                continuation.resume(returning: $0)
            } == .terminateLater)
        }

        #expect(approved)
        #expect(firstPanels.decisionTabs.count == 1)
        #expect(secondPanels.decisionTabs.count == 1)
        #expect(await firstRecovery.commitCount >= 1)
        #expect(await secondRecovery.commitCount >= 1)
        #expect(await firstRecovery.latestTabCount() == 1)
        #expect(await secondRecovery.latestTabCount() == 1)
    }

    @Test @MainActor func redCloseReviewsOnlyItsOwningWindow() async {
        let coordinator = ApplicationTerminationCoordinator()
        var approvedWindow: NSWindow?
        let closeSpy: @MainActor (NSWindow) -> Void = { window in
            approvedWindow = window
        }
        let (first, _, firstEditor, firstPanels, _) = await makeController(
            decisions: [.discard],
            terminationCoordinator: coordinator,
            approvedWindowClose: closeSpy
        )
        let (second, _, secondEditor, secondPanels, _) = await makeController(
            decisions: [.cancel],
            terminationCoordinator: coordinator,
            approvedWindowClose: closeSpy
        )
        defer {
            first.close()
            second.close()
        }
        dirty(firstEditor, with: "close this window")
        dirty(secondEditor, with: "leave this window alone")

        #expect(first.windowShouldClose(first.window!) == false)
        for _ in 0..<200 where approvedWindow == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(approvedWindow === first.window)
        #expect(firstPanels.decisionTabs.count == 1)
        #expect(secondPanels.decisionTabs.isEmpty)
        let newScratch = NSMenuItem(
            title: "New Scratch",
            action: #selector(DuckpadWindowController.performNewScratch(_:)),
            keyEquivalent: ""
        )
        #expect(second.validateMenuItem(newScratch))
    }

    @Test @MainActor func nativeCleanWindowCloseDetachesAndPublishesLifecycleOnce() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (controller, _, _, _, _) = await makeController(
            decisions: [],
            terminationCoordinator: coordinator
        )
        var closeCount = 0
        controller.onClosed = { closeCount += 1 }
        #expect(coordinator.attachedWindowCount == 1)

        controller.window?.close()

        #expect(closeCount == 1)
        #expect(coordinator.attachedWindowCount == 0)
        #expect(controller.window == nil)
        controller.close()
        #expect(closeCount == 1)
    }

    @Test @MainActor func lateAttachedWindowJoinsApplicationTerminationReview() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (first, _, firstEditor, firstPanels, _) = await makeController(
            decisions: [.discard],
            blocksDecisions: true,
            terminationCoordinator: coordinator
        )
        dirty(firstEditor, with: "hold application review")
        var applicationReply: Bool?
        #expect(coordinator.applicationShouldTerminate { applicationReply = $0 } == .terminateLater)
        for _ in 0..<500 where firstPanels.decisionTabs.isEmpty { await Task.yield() }

        let secondRecovery = RoutingRecoveryStore()
        let (second, _, secondEditor, secondPanels, _) = await makeController(
            decisions: [.discard],
            recoveryStore: secondRecovery,
            terminationCoordinator: coordinator
        )
        defer {
            first.close()
            second.close()
        }
        let newScratch = NSMenuItem(
            title: "New Scratch",
            action: #selector(DuckpadWindowController.performNewScratch(_:)),
            keyEquivalent: ""
        )
        #expect(!second.validateMenuItem(newScratch))
        dirty(secondEditor, with: "late restored dirty window")
        firstPanels.releaseDecisions()
        for _ in 0..<2_000 where applicationReply == nil { await Task.yield() }

        #expect(applicationReply == true)
        #expect(secondPanels.decisionTabs.count == 1)
        #expect(await secondRecovery.commitCount >= 1)
    }

    @Test @MainActor func applicationTerminationWaitsForClosedWindowRecoveryReset() async {
        let coordinator = ApplicationTerminationCoordinator()
        let recoveryStore = RoutingRecoveryStore()
        await recoveryStore.armBlockedReset()
        let (controller, _, _, _, _) = await makeController(
            decisions: [],
            recoveryStore: recoveryStore,
            terminationCoordinator: coordinator,
            approvedWindowClose: { $0.windowController?.close() }
        )

        #expect(controller.windowShouldClose(controller.window!) == false)
        for _ in 0..<200 where !(await recoveryStore.hasEnteredBlockedReset()) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard await recoveryStore.hasEnteredBlockedReset() else {
            Issue.record("window close did not start its tracked recovery reset")
            controller.close()
            return
        }
        #expect(controller.window == nil)
        #expect(coordinator.attachedWindowCount == 0)
        var applicationReply: Bool?
        #expect(coordinator.applicationShouldTerminate { applicationReply = $0 } == .terminateLater)
        for _ in 0..<100 { await Task.yield() }
        #expect(applicationReply == nil)

        let lateRecovery = RoutingRecoveryStore()
        let (late, _, lateEditor, latePanels, _) = await makeController(
            decisions: [.discard],
            recoveryStore: lateRecovery,
            terminationCoordinator: coordinator
        )
        defer { late.close() }
        dirty(lateEditor, with: "attached while close cleanup was blocked")

        await recoveryStore.releaseBlockedReset()
        for _ in 0..<2_000 where applicationReply == nil { await Task.yield() }
        #expect(applicationReply == true)
        #expect(await recoveryStore.latestTabCount() == nil)
        #expect(latePanels.decisionTabs.count == 1)
        #expect(await lateRecovery.commitCount >= 1)
    }

    @Test @MainActor func failedWindowCleanupDeniesQuitAndRetriesOnNextRequest() async {
        let coordinator = ApplicationTerminationCoordinator()
        var attempts = 0
        coordinator.trackWindowCloseCleanup {
            attempts += 1
            return attempts > 1
        }
        var firstReply: Bool?
        #expect(coordinator.applicationShouldTerminate { firstReply = $0 } == .terminateLater)
        for _ in 0..<2_000 where firstReply == nil { await Task.yield() }
        #expect(firstReply == false)
        #expect(attempts >= 1)

        var secondReply: Bool?
        #expect(coordinator.applicationShouldTerminate { secondReply = $0 } == .terminateLater)
        for _ in 0..<2_000 where secondReply == nil { await Task.yield() }
        #expect(secondReply == true)
        #expect(attempts == 2)
    }

    @Test @MainActor func routedCloseSaveFailurePresentsOnceAndRetriesLatestRevision() async {
        let saveURL = URL(fileURLWithPath: "/tmp/duckpad-close-retry.txt")
        let genericPresenter = RecoveryErrorPresenterSpy()
        let (controller, workspace, editor, panels, files) = await makeController(
            decisions: [.save],
            saveURL: saveURL,
            writeError: .io("first write fails"),
            errorPresenter: genericPresenter
        )
        defer { controller.close() }

        dirty(editor, with: "reviewed")
        let originalTab = workspace.snapshot().tabs[0]
        let failedClose = controller.performClose(originalTab.id)
        await failedClose.value

        #expect(workspace.snapshot().tabs.contains(where: { $0.id == originalTab.id }))
        #expect(workspace.snapshot().tabs.first(where: { $0.id == originalTab.id })?.isDirty == true)
        #expect(panels.failures.count == 1)
        #expect(panels.fileFailureRetries.count == 1)
        #expect(genericPresenter.failures.isEmpty)

        // The retry starts a fresh serialized review. It must save the text and
        // revision accepted after the failed attempt, not the stale review.
        // Drain the earlier edit's pending workspace transaction before the
        // synchronous test edit; polling after a rejected edit cannot revive it.
        await workspace.waitForPendingPersistence()
        let failedRevision = workspace.snapshot().tabs.first(where: { $0.id == originalTab.id })!.buffer.revision
        dirty(editor, with: "newest revision 🙂")
        #expect(workspace.snapshot().tabs.first(where: { $0.id == originalTab.id })!.buffer.revision == failedRevision + 1)
        #expect(editor.textView.string == "newest revision 🙂")
        #expect(editor.snapshot(for: originalTab.buffer.bufferID)?.text == "newest revision 🙂")
        await workspace.waitForPendingPersistence()
        await files.setWriteError(nil)
        panels.retryLastFileFailure()
        for _ in 0..<200 where workspace.snapshot().tabs.contains(where: { $0.id == originalTab.id }) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(!workspace.snapshot().tabs.contains(where: { $0.id == originalTab.id }))
        #expect(await files.text(at: saveURL) == "newest revision 🙂")
        #expect(panels.failures.count == 1)
        #expect(genericPresenter.failures.isEmpty)
    }

    @Test @MainActor func terminationFileRetryResumesReviewFlushAndNewTerminateReply() async {
        let saveURL = URL(fileURLWithPath: "/tmp/duckpad-termination-retry.txt")
        let recoveryStore = RoutingRecoveryStore()
        let genericPresenter = RecoveryErrorPresenterSpy()
        let (controller, workspace, editor, panels, files) = await makeController(
            decisions: [.save, .discard],
            saveURL: saveURL,
            writeError: .io("first termination save fails"),
            errorPresenter: genericPresenter,
            recoveryStore: recoveryStore
        )
        defer { controller.close() }

        dirty(editor, with: "first reviewed revision")
        let firstTabID = workspace.snapshot().tabs[0].id
        _ = await workspace.addScratch()
        let secondTabID = workspace.snapshot().tabs.first(where: \.isActive)!.id
        dirty(editor, with: "second tab remains to review")

        let coordinator = controller.terminationCoordinator!
        var retryRequests = 0
        var retryGateReply: NSApplication.TerminateReply?

        var initialReplyCount = 0
        let initialReply = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate {
                initialReplyCount += 1
                continuation.resume(returning: $0)
            } == .terminateLater)
        }
        #expect(!initialReply)
        #expect(initialReplyCount == 1)
        #expect(panels.failures.count == 1)
        #expect(panels.fileFailureRetries.count == 1)
        #expect(genericPresenter.failures.isEmpty)
        #expect(workspace.snapshot().tabs.contains(where: { $0.id == firstTabID }))
        #expect(workspace.snapshot().tabs.contains(where: { $0.id == secondTabID }))

        // saveBeforeClosing activated the failed tab. Edit it after the first
        // reply to prove Retry reviews and persists the latest revision. Drain
        // the explicit workspace persistence seam first: an edit attempted
        // during that transaction is correctly rejected and cannot be made
        // reliable by polling after the fact.
        await workspace.waitForPendingPersistence()
        #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == firstTabID)
        #expect(editor.textView.string == "first reviewed revision")
        let failedRevision = workspace.snapshot().tabs.first(where: { $0.id == firstTabID })!.buffer.revision
        dirty(editor, with: "newest termination revision 🙂")
        #expect(workspace.snapshot().tabs.first(where: { $0.id == firstTabID })!.buffer.revision == failedRevision + 1)
        #expect(editor.textView.string == "newest termination revision 🙂")
        await files.setWriteError(nil)
        let recoveryCommitsBeforeRetry = await recoveryStore.commitCount
        let retriedTerminationReply = await withCheckedContinuation { continuation in
            coordinator.installApplicationRetryHandler { [weak coordinator] in
                guard let coordinator else { return }
                retryRequests += 1
                retryGateReply = coordinator.applicationShouldTerminate {
                    continuation.resume(returning: $0)
                }
            }
            panels.retryLastFileFailure()
        }

        #expect(retryRequests == 1)
        #expect(retryGateReply == .terminateLater)
        #expect(retriedTerminationReply)
        #expect(await files.text(at: saveURL) == "newest termination revision 🙂")
        #expect(workspace.snapshot().tabs.contains(where: { $0.id == firstTabID }))
        #expect(!workspace.snapshot().tabs.contains(where: { $0.id == secondTabID }))
        #expect(!controller.hasDirtyDocuments)
        #expect(panels.decisionTabs.count == 2)
        #expect(Set(panels.decisionTabs).count == 2)
        #expect(await recoveryStore.commitCount == recoveryCommitsBeforeRetry + 2)
        #expect(panels.failures.count == 1)
        #expect(genericPresenter.failures.isEmpty)
    }

    @Test @MainActor func appTerminationReviewsEveryDirtyTabSerially() async {
        let (controller, workspace, editor, panels, _) = await makeController(decisions: [.discard, .discard])
        dirty(editor, with: "first")
        _ = await workspace.addScratch()
        dirty(editor, with: "second")
        let coordinator = controller.terminationCoordinator!
        let reply = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(reply)
        #expect(panels.decisionTabs.count == 2)
        #expect(Set(panels.decisionTabs).count == 2)
        #expect(!controller.hasDirtyDocuments)
        controller.close()
    }

    @Test @MainActor func viewOptionsAreInertDuringTerminationReview() async {
        let (controller, _, editor, panels, _) = await makeController(
            decisions: [.cancel],
            blocksDecisions: true
        )
        defer { controller.close() }
        dirty(editor, with: "keep this")
        let review = Task { @MainActor in
            await controller.reviewDirtyDocumentsForTermination()
        }
        for _ in 0..<200 where panels.decisionTabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(panels.decisionTabs.count == 1)

        let wordWrap = NSMenuItem(
            title: "Word Wrap",
            action: #selector(DuckpadWindowController.performToggleWordWrap(_:)),
            keyEquivalent: ""
        )
        #expect(!controller.validateMenuItem(wordWrap))
        controller.performToggleWordWrap(wordWrap)
        #expect(editor.isWordWrapEnabled)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let delete = NSMenuItem(
            title: "Delete",
            action: #selector(DuckpadWindowController.performDelete(_:)),
            keyEquivalent: ""
        )
        #expect(!controller.validateMenuItem(delete))
        controller.performDelete(delete)
        #expect(editor.textView.string == "keep this")

        panels.releaseDecisions()
        #expect(await review.value == false)
        #expect(controller.validateMenuItem(wordWrap))
        #expect(wordWrap.state == .on)
        #expect(controller.validateMenuItem(delete))
    }

    @Test @MainActor func terminationLocksChromeAcrossReadyEventsAndRestoresOnlyAfterCancel() async {
        let (controller, workspace, editor, panels, _) = await makeController(
            decisions: [.cancel],
            blocksDecisions: true
        )
        defer { controller.close() }
        let firstID = workspace.snapshot().tabs[0].id
        _ = await workspace.addScratch()
        let activeID = workspace.snapshot().tabs.first(where: \.isActive)!.id
        dirty(editor, with: "keep active document")

        var replies: [Bool] = []
        let coordinator = controller.terminationCoordinator!
        #expect(coordinator.applicationShouldTerminate { replies.append($0) } == .terminateLater)

        var chrome = controller.workspaceChromeSmokeState()
        #expect(!chrome.interactionsEnabled)
        #expect(!chrome.languageStatusEnabled)
        #expect(!chrome.extensionStatusEnabled)

        for _ in 0..<200 where panels.decisionTabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(panels.decisionTabs.count == 1)

        // A ready-state workspace publication must not reopen UI admission.
        _ = await workspace.setPinned(activeID, isPinned: true)
        chrome = controller.workspaceChromeSmokeState()
        #expect(!chrome.interactionsEnabled)

        let originalCount = workspace.snapshot().tabs.count
        controller.performNewScratch()
        controller.performActivate(firstID)
        controller.tabStrip.performMiddleClick(tabID: activeID)
        let documentPanel = controller.tabStrip.documentSwitcher.documentPanel
        documentPanel.apply(tabs: workspace.snapshot().tabs)
        documentPanel.setQuery(workspace.snapshot().tabs[0].title)
        documentPanel.activateSelectedResult()
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.snapshot().tabs.count == originalCount)
        #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == activeID)

        let language = NSMenuItem(
            title: "Language",
            action: #selector(DuckpadWindowController.performShowLanguageChooser(_:)),
            keyEquivalent: ""
        )
        #expect(!controller.validateMenuItem(language))

        panels.releaseDecisions()
        for _ in 0..<200 where replies.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(replies == [false])
        chrome = controller.workspaceChromeSmokeState()
        #expect(chrome.interactionsEnabled)
        #expect(chrome.languageStatusEnabled)
        #expect(chrome.extensionStatusEnabled)
    }

    @Test @MainActor func delayedStartupReadyEventCannotReenablePreparedTerminationAdmission() async {
        _ = NSApplication.shared
        let store = DelayedStartupSessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        defer { controller.close() }

        controller.start()
        await store.waitUntilLoadEntered()
        #expect(controller.beginTerminationReviewAdmission())
        #expect(!controller.workspaceChromeSmokeState().interactionsEnabled)

        await store.releaseLoad()
        await controller.waitForStartup()
        #expect(workspace.snapshot().startup == .ready)
        let chrome = controller.workspaceChromeSmokeState()
        #expect(!chrome.interactionsEnabled)
        #expect(!chrome.languageStatusEnabled)
        #expect(!chrome.extensionStatusEnabled)
        #expect(await controller.continuePreparedTerminationReview())
    }

    @Test @MainActor func redCloseThenRepeatedQuitTriggersShareOneCancelledReview() async {
        var approvedCloseCount = 0
        var appReplies: [Bool] = []
        let (controller, _, editor, panels, _) = await makeController(
            decisions: [.cancel],
            blocksDecisions: true,
            approvedWindowClose: { _ in approvedCloseCount += 1 }
        )
        controller.showWindow(nil)
        dirty(editor, with: "keep this")

        #expect(controller.windowShouldClose(controller.window!) == false)
        #expect(controller.windowShouldClose(controller.window!) == false)
        let coordinator = controller.terminationCoordinator!
        #expect(coordinator.applicationShouldTerminate { appReplies.append($0) } == .terminateLater)
        #expect(coordinator.applicationShouldTerminate { appReplies.append($0) } == .terminateLater)
        for _ in 0..<200 where panels.decisionTabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(panels.decisionTabs.count == 1)

        panels.releaseDecisions()
        for _ in 0..<200 where appReplies.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(appReplies == [false, false])
        #expect(approvedCloseCount == 0)
        #expect(controller.hasDirtyDocuments)
        #expect(controller.window?.isVisible == true)
        controller.close()
    }

    @Test @MainActor func repeatedQuitThenRedCloseTriggersShareOneFailedSaveReview() async {
        let saveURL = URL(fileURLWithPath: "/tmp/duckpad-overlap-save-failure.txt")
        var approvedCloseCount = 0
        var appReplies: [Bool] = []
        let (controller, _, editor, panels, _) = await makeController(
            decisions: [.save],
            saveURL: saveURL,
            writeError: .io("overlap failure"),
            blocksDecisions: true,
            approvedWindowClose: { _ in approvedCloseCount += 1 }
        )
        controller.showWindow(nil)
        dirty(editor, with: "unsaved")

        let coordinator = controller.terminationCoordinator!
        #expect(coordinator.applicationShouldTerminate { appReplies.append($0) } == .terminateLater)
        #expect(coordinator.applicationShouldTerminate { appReplies.append($0) } == .terminateLater)
        for _ in 0..<200 where panels.decisionTabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.windowShouldClose(controller.window!) == false)
        #expect(controller.windowShouldClose(controller.window!) == false)
        #expect(panels.decisionTabs.count == 1)

        panels.releaseDecisions()
        for _ in 0..<200 where appReplies.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(appReplies == [false, false])
        #expect(approvedCloseCount == 0)
        #expect(panels.decisionTabs.count == 1)
        #expect(panels.failures.count == 1)
        #expect(controller.hasDirtyDocuments)
        #expect(controller.window?.isVisible == true)
        controller.close()
    }

    @Test @MainActor func searchMenuRoutesAndPanelCollapsesWithoutBlankEditorStrip() {
        let controller = DuckpadWindowController(
            workspace: ScratchWorkspaceUseCase(store: RoutingSessionStore()),
            automaticallyStarts: false
        )
        controller.showWindow(nil)
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let search = menu.items.compactMap { $0.submenu }.first(where: { $0.title == "Search" })
        #expect(search?.items.first(where: { $0.title == "Find…" })?.keyEquivalent == "f")
        #expect(search?.items.first(where: { $0.title == "Find Next" })?.keyEquivalent == "g")
        let previousModifiers = search?.items.first(where: { $0.title == "Find Previous" })?.keyEquivalentModifierMask
        #expect(previousModifiers?.contains(.command) == true)
        #expect(previousModifiers?.contains(.shift) == true)
        #expect(search?.items.first(where: { $0.title == "Replace…" })?.keyEquivalent == "h")

        controller.performShowFind()
        #expect(controller.searchPanelSmokeState().isVisible)
        #expect(controller.searchPanelSmokeState().height > 0)
        controller.performCloseFindPanel()
        #expect(!controller.searchPanelSmokeState().isVisible)
        #expect(controller.searchPanelSmokeState().height == 0)
        controller.close()
    }
}
