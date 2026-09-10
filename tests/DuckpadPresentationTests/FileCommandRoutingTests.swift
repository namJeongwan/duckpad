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
    private var commitError: SessionStoreError?
    private var blocksCommit = false
    private var commitEntered = false
    func setCommitError(_ error: SessionStoreError?) { commitError = error }
    func blockCommit() { blocksCommit = true; commitEntered = false }
    func hasEnteredCommit() -> Bool { commitEntered }
    func releaseCommit() { blocksCommit = false }
    private var loadError: SessionStoreError?
    private(set) var commitCount = 0
    private var blockNextReset = false
    private var resetEntered = false
    private var releaseReset = false
    private var blocksLoad = false
    private var loadEntered = false
    func blockLoad() { blocksLoad = true; loadEntered = false }
    func hasEnteredLoad() -> Bool { loadEntered }
    func releaseLoad() { blocksLoad = false }
    func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? {
        loadEntered = true
        while blocksLoad { await Task.yield() }
        if let loadError { throw loadError }
        return stored
    }
    func commit(_ archive: RecoveryArchive, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        commitEntered = true
        while blocksCommit { await Task.yield() }
        if let commitError { throw commitError }
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
    private var readPaths: [String] = []
    private var generation: UInt64 = 0
    private var forcedWriteError: TextFileStoreError?
    private(set) var renewedPaths: [String] = []
    private var renewalError: TextFileStoreError?
    func setRenewalError(_ error: TextFileStoreError?) { renewalError = error }
    func renewSecurityScopedAccess(to url: URL, ownerID: UUID) async throws(TextFileStoreError) -> SecurityScopedFileAccess {
        renewedPaths.append(url.path)
        if let renewalError { throw renewalError }
        forcedWriteError = nil
        return SecurityScopedFileAccess(url: url, bookmark: Data("renewed-grant".utf8))
    }
    private var blockNextRead = false
    private var blockedReadEntered = false
    private var releaseBlockedRead = false
    private var blockNextWrite = false
    private var blockedWriteEntered = false
    private var releaseBlockedWrite = false
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { url.standardizedFileURL }
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        readPaths.append(url.path)
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
        if blockNextWrite {
            blockNextWrite = false
            blockedWriteEntered = true
            while !releaseBlockedWrite { await Task.yield() }
        }
        let current = values[url.path]
        if let expectedIdentity, current?.identity != expectedIdentity { throw .conflict(current: current?.identity) }
        generation += 1
        let identity = FileIdentity(canonicalPath: url.path, device: 1, inode: 1, byteCount: UInt64(data.count), modifiedNanoseconds: Int64(generation), contentToken: "routing-\(generation)")
        values[url.path] = FileReadResult(data: data, identity: identity)
        return FileWriteReceipt(identity: identity)
    }
    func seed(_ text: String, at url: URL) {
        seed(Data(text.utf8), at: url)
    }
    func seed(_ data: Data, at url: URL) {
        generation += 1
        let identity = FileIdentity(canonicalPath: url.path, device: 1, inode: 1, byteCount: UInt64(data.count), modifiedNanoseconds: Int64(generation), contentToken: "routing-\(generation)")
        values[url.path] = FileReadResult(data: data, identity: identity)
    }
    func text(at url: URL) -> String? { values[url.path].flatMap { String(data: $0.data, encoding: .utf8) } }
    func data(at url: URL) -> Data? { values[url.path]?.data }
    func result(at url: URL) -> FileReadResult? { values[url.path] }
    func orderedReadPaths() -> [String] { readPaths }
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
    func armNextWrite() {
        blockNextWrite = true
        blockedWriteEntered = false
        releaseBlockedWrite = false
    }
    func waitUntilWriteIsBlocked() async {
        while !blockedWriteEntered { await Task.yield() }
    }
    func releaseWrite() { releaseBlockedWrite = true }
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
    var saveURLs: [URL] = []
    var folderURL: URL?
    private(set) var openRequests = 0
    private(set) var saveRequests = 0
    private(set) var saveAccessRequests: [URL] = []
    var saveAccessURL: URL?
    var onSaveAccess: (@MainActor () async -> Void)?
    func chooseSaveAccessURL(for url: URL, attachedTo window: NSWindow?) async -> URL? {
        saveAccessRequests.append(url)
        await onSaveAccess?()
        return saveAccessURL
    }
    private(set) var folderRequests = 0
    private(set) var failures: [FileOperationFailure] = []
    private(set) var fileFailureRetries: [@MainActor () -> Void] = []
    var conflictResolutions: [FileConflictResolution] = []
    private(set) var comparisons: [ExternalFileComparison] = []
    var decisions: [CloseDecision] = []
    var allDecision: CloseDecision?
    var onAllDecision: (@MainActor () async -> Void)?
    private(set) var allDecisionTabs: [[TabSnapshot]] = []
    var blocksDecisions = false
    var blocksSavePanel = false
    private var savePanelEntered = false
    private(set) var decisionTabs: [String] = []
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    private var savePanelWaiters: [CheckedContinuation<Void, Never>] = []
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { openRequests += 1; return openURL }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        saveRequests += 1
        savePanelEntered = true
        if blocksSavePanel {
            await withCheckedContinuation { savePanelWaiters.append($0) }
        }
        return saveURLs.isEmpty ? saveURL : saveURLs.removeFirst()
    }
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
    func decisionForAll(_ tabs: [TabSnapshot], saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision? {
        guard let allDecision else { return nil }
        allDecisionTabs.append(tabs)
        await onAllDecision?()
        return allDecision
    }
    func releaseDecisions() {
        blocksDecisions = false
        let waiters = decisionWaiters
        decisionWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    func waitUntilSavePanelEntered() async {
        while !savePanelEntered { await Task.yield() }
    }
    func releaseSavePanel() {
        blocksSavePanel = false
        let waiters = savePanelWaiters
        savePanelWaiters = []
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

@Test @MainActor func externalOpenBatchPublishesSuccessfulRecentDocumentURLs() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let first = URL(fileURLWithPath: "/tmp/duckpad-finder-first.txt")
    let second = URL(fileURLWithPath: "/tmp/duckpad-finder-second.swift")
    await files.seed("first", at: first)
    await files.seed("let second = 2", at: second)
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        automaticallyStarts: false
    )
    defer { controller.close() }
    var recent: [URL] = []
    controller.onDocumentURLUsed = { recent.append($0) }
    controller.start()

    let succeeded = await withCheckedContinuation { continuation in
        controller.openExternalURLs([first, second]) {
            continuation.resume(returning: $0)
        }
    }

    #expect(succeeded)
    #expect(recent.map(\.path) == [first.path, second.path])
    #expect(workspace.snapshot().tabs.compactMap(\.fullPath) == [first.path, second.path])
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.fullPath == second.path)
}

@Test @MainActor func concurrentExternalOpenBatchesRemainContiguousAndFIFO() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let urls = (1...4).map { URL(fileURLWithPath: "/tmp/duckpad-batch-\($0).txt") }
    for (index, url) in urls.enumerated() { await files.seed("\(index)", at: url) }
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await files.armNextRead()
    let first = Task { @MainActor in
        await withCheckedContinuation { continuation in
            controller.openExternalURLs(Array(urls[0...1])) { continuation.resume(returning: $0) }
        }
    }
    await files.waitUntilReadIsBlocked()
    let second = Task { @MainActor in
        await withCheckedContinuation { continuation in
            controller.openExternalURLs(Array(urls[2...3])) { continuation.resume(returning: $0) }
        }
    }
    for _ in 0..<20 { await Task.yield() }
    await files.releaseRead()

    #expect(await first.value)
    #expect(await second.value)
    #expect(await files.orderedReadPaths() == urls.map(\.path))
    #expect(workspace.snapshot().tabs.compactMap(\.fullPath) == urls.map(\.path))
}

@Test @MainActor func saveAllWritesEveryDirtyTabAndRestoresOriginalSelection() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let panels = PanelFake()
    let firstURL = URL(fileURLWithPath: "/tmp/duckpad-save-all-first.txt")
    let secondURL = URL(fileURLWithPath: "/tmp/duckpad-save-all-second.txt")
    panels.saveURLs = [firstURL, secondURL]
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        filePanels: panels,
        fileConflictPresenter: panels,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    editor.textView.insertText("first", replacementRange: NSRange(location: 0, length: 0))
    await workspace.waitForPendingPersistence()
    _ = await workspace.addScratch()
    editor.textView.insertText("second", replacementRange: NSRange(location: 0, length: 0))
    await workspace.waitForPendingPersistence()
    let originalTabID = workspace.snapshot().tabs.first(where: \.isActive)?.id
    var recent: [URL] = []
    controller.onDocumentURLUsed = { recent.append($0) }

    controller.performSaveAll()
    for _ in 0..<2_000 where workspace.snapshot().tabs.contains(where: \.isDirty) {
        await Task.yield()
    }

    #expect(await files.text(at: firstURL) == "first")
    #expect(await files.text(at: secondURL) == "second")
    #expect(workspace.snapshot().tabs.allSatisfy { !$0.isDirty })
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == originalTabID)
    #expect(panels.saveRequests == 2)
    #expect(recent.map(\.path) == [firstURL.path, secondURL.path])
}

@Test @MainActor func saveCopyConflictRetryStartsFreshPanelAndIdentityCycle() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let panels = PanelFake()
    let racedURL = URL(fileURLWithPath: "/tmp/duckpad-copy-routed-race.txt")
    let retryURL = URL(fileURLWithPath: "/tmp/duckpad-copy-routed-retry.txt")
    await files.seed("consented", at: racedURL)
    panels.saveURL = racedURL
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: FileDocumentUseCase(workspace: workspace, editor: editor, store: files),
        filePanels: panels,
        fileConflictPresenter: panels,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    editor.textView.insertText("copy me", replacementRange: NSRange(location: 0, length: 0))
    await workspace.waitForPendingPersistence()
    await files.armNextWrite()

    controller.performSaveCopyAs()
    await files.waitUntilWriteIsBlocked()
    await files.seed("external replacement", at: racedURL)
    await files.releaseWrite()
    for _ in 0..<2_000 where panels.failures.isEmpty { await Task.yield() }

    guard case .store(.conflict) = panels.failures.first else {
        Issue.record("routed copy conflict was not presented")
        return
    }
    #expect(await files.text(at: racedURL) == "external replacement")
    panels.saveURL = retryURL
    panels.retryLastFileFailure()
    for _ in 0..<2_000 where await files.text(at: retryURL) == nil { await Task.yield() }

    #expect(panels.saveRequests == 2)
    #expect(await files.text(at: retryURL) == "copy me")
    #expect(workspace.activeFileContext()?.binding == nil)
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == true)
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

@Test @MainActor func controllerOpensExplicitUTF16AndConvertsDurableFormat() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let url = URL(fileURLWithPath: "/tmp/duckpad-routing-format.txt")
    let original = "한\r둘🙂"
    await files.seed(
        TextFileCodec.encode(
            original,
            encoding: .utf16LittleEndian,
            byteOrderMark: .absent
        ),
        at: url
    )
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.openURL = url
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

    await controller.routeOpenFile(encodingHint: .utf16LittleEndian)
    #expect(editor.textView.string == original)
    #expect(controller.fileFormatStatusSmokeState().encoding == .utf16LittleEndian)
    #expect(controller.fileFormatStatusSmokeState().byteOrderMark == .absent)
    #expect(controller.fileFormatStatusSmokeState().lineEnding == .cr)
    let originalEncodingItem = NSMenuItem(
        title: "UTF-16 LE without BOM",
        action: #selector(DuckpadWindowController.performConvertToUTF16LittleEndianWithoutBOM(_:)),
        keyEquivalent: ""
    )
    #expect(controller.validateMenuItem(originalEncodingItem))
    #expect(originalEncodingItem.state == .on)

    await controller.routeSaveFile(conversion: TextFileConversion(
        encoding: .utf8,
        byteOrderMark: .present,
        lineEnding: .crlf
    ))
    let saved = try #require(await files.data(at: url))
    #expect(saved.starts(with: Data([0xEF, 0xBB, 0xBF])))
    #expect(String(data: saved.dropFirst(3), encoding: .utf8) == "한\r\n둘🙂")
    let binding = try #require(workspace.activeFileContext()?.binding)
    #expect(binding.encoding == .utf8)
    #expect(binding.byteOrderMark == .present)
    #expect(binding.lineEnding == .crlf)
    #expect(controller.fileFormatStatusSmokeState().text == "UTF-8 BOM")
    #expect(controller.fileFormatStatusSmokeState().isEnabled)
    let encodingItem = NSMenuItem(
        title: "UTF-8 with BOM",
        action: #selector(DuckpadWindowController.performConvertToUTF8BOM(_:)),
        keyEquivalent: ""
    )
    let endingItem = NSMenuItem(
        title: "Windows (CRLF)",
        action: #selector(DuckpadWindowController.performConvertToCRLF(_:)),
        keyEquivalent: ""
    )
    #expect(controller.validateMenuItem(encodingItem))
    #expect(controller.validateMenuItem(endingItem))
    #expect(encodingItem.state == .on)
    #expect(endingItem.state == .on)
    let endingsMenu = DuckpadMainMenuFactory.makeLineEndingMenu(target: controller)
    endingsMenu.update()
    #expect(endingsMenu.items.map(\.title) == ["Unix (LF)", "Windows (CRLF)", "Classic Mac (CR)"])
    #expect(endingsMenu.items.allSatisfy { $0.submenu == nil && $0.target === controller })
    #expect(endingsMenu.items.filter { $0.state == .on }.map(\.action) == [endingItem.action])
    let encodingsMenu = DuckpadMainMenuFactory.makeEncodingMenu(target: controller)
    encodingsMenu.update()
    #expect(encodingsMenu.items.allSatisfy { $0.submenu == nil })
    #expect(encodingsMenu.items.filter { $0.state == .on }.map(\.action) == [encodingItem.action])
}

@Test @MainActor func scratchFormatConversionUsesSaveAsAndPreservesChosenBytes() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let url = URL(fileURLWithPath: "/tmp/duckpad-routing-scratch-format.txt")
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.saveURL = url
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
    editor.textView.insertText("가\r나🙂", replacementRange: NSRange(location: 0, length: 0))

    await controller.routeSaveFile(conversion: TextFileConversion(
        encoding: .utf16BigEndian,
        byteOrderMark: .absent,
        lineEnding: .lf
    ))

    #expect(panels.saveRequests == 1)
    let saved = try #require(await files.data(at: url))
    #expect(!saved.starts(with: Data([0xFE, 0xFF])))
    #expect(try TextFileCodec.decode(saved, assuming: .utf16BigEndian).text == "가\n나🙂")
    let binding = try #require(workspace.activeFileContext()?.binding)
    #expect(binding.encoding == .utf16BigEndian)
    #expect(binding.byteOrderMark == .absent)
    #expect(binding.lineEnding == .lf)
    #expect(controller.fileFormatStatusSmokeState().text == "UTF-16 BE")
}

@Test @MainActor func formatSaveAsRejectsTabSwitchWhilePanelIsOpen() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let url = URL(fileURLWithPath: "/tmp/duckpad-routing-stale-format.txt")
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.saveURL = url
    panels.blocksSavePanel = true
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
    let original = try #require(workspace.activeFileContext())

    let save = Task { @MainActor in
        await controller.routeSaveFile(
            conversion: TextFileConversion(
                encoding: .utf16LittleEndian,
                byteOrderMark: .present,
                lineEnding: .crlf
            ),
            expectedContext: original
        )
    }
    await panels.waitUntilSavePanelEntered()
    #expect(await workspace.addScratch() == .applied(.saved))
    panels.releaseSavePanel()
    await save.value

    #expect(await files.data(at: url) == nil)
    #expect(workspace.activeFileContext()?.tabID != original.tabID)
    #expect(workspace.activeFileContext()?.binding == nil)
    #expect(panels.failures.isEmpty)
}

@Test @MainActor func immediateTerminationJoinsAcceptedBlockedFormatConversion() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let recoveryStore = RoutingRecoveryStore()
    let recovery = SessionRecoveryUseCase(
        workspace: workspace,
        editor: editor,
        store: recoveryStore,
        debounce: .seconds(60)
    )
    let coordinator = ApplicationTerminationCoordinator()
    let url = URL(fileURLWithPath: "/tmp/duckpad-routing-format-termination.txt")
    await files.seed("first\nsecond", at: url)
    let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        fileUseCase: fileUseCase,
        recoveryUseCase: recovery,
        terminationCoordinator: coordinator,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    guard case .opened = await fileUseCase.open(url) else {
        Issue.record("format termination fixture did not open")
        return
    }
    await files.armNextWrite()

    controller.performConvertToCRLF()
    var terminationReply: Bool?
    #expect(coordinator.applicationShouldTerminate { terminationReply = $0 } == .terminateLater)
    await files.waitUntilWriteIsBlocked()
    for _ in 0..<20 { await Task.yield() }
    #expect(terminationReply == nil)
    #expect(await recoveryStore.commitCount == 0)

    await files.releaseWrite()
    for _ in 0..<2_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(await files.text(at: url) == "first\r\nsecond")
    #expect(workspace.activeFileContext()?.binding?.lineEnding == .crlf)
    #expect(await recoveryStore.commitCount == 1)
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
        approvedWindowClose: (@MainActor (NSWindow) -> Void)? = nil,
        waitForStartup: Bool = true
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
        if waitForStartup { await controller.waitForStartup() }
        return (controller, workspace, editor, panels, files)
    }

    @MainActor
    private func dirty(_ editor: TextViewEditorAdapter, with text: String) {
        editor.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: (editor.textView.string as NSString).length),
            with: text
        )
    }

    @Test @MainActor func sessionQuitRestoresUntitledAndDirtyFileWithoutWritingOriginal() async throws {
        let recovery = RoutingRecoveryStore()
        let (controller, workspace, editor, panels, files) = await makeController(decisions: [], recoveryStore: recovery)
        dirty(editor, with: "untitled 한글 🙂")
        let url = URL(fileURLWithPath: "/tmp/duckpad-preserved-source.txt")
        await files.seed("original on disk", at: url)
        let opened = await withCheckedContinuation { continuation in
            controller.openExternalURLs([url]) { continuation.resume(returning: $0) }
        }
        try #require(opened)
        dirty(editor, with: "edited without saving")
        let before = workspace.snapshot().tabs
        try #require(before.count == 2)
        let coordinator = controller.terminationCoordinator!
        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(approved)
        #expect(workspace.snapshot().tabs == before)
        #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
        #expect(panels.saveRequests == 0)
        #expect(await files.text(at: url) == "original on disk")
        controller.close()
        let (reopened, restored, restoredEditor, _, _) = await makeController(decisions: [], recoveryStore: recovery)
        defer { reopened.close() }
        #expect(restored.snapshot().tabs == before)
        #expect(restoredEditor.snapshot(for: before[0].buffer.bufferID)?.text == "untitled 한글 🙂")
        #expect(restoredEditor.snapshot(for: before[1].buffer.bufferID)?.text == "edited without saving")
    }

    @Test @MainActor func redCloseJoinedByQuitKeepsPreservedWindowLockedThroughReply() async {
        let recovery = RoutingRecoveryStore()
        let (controller, _, editor, panels, _) = await makeController(decisions: [], recoveryStore: recovery)
        defer { controller.close() }
        dirty(editor, with: "locked until quit")
        controller.showWindow(nil)
        await recovery.blockCommit()
        #expect(!controller.windowShouldClose(controller.window!))
        for _ in 0..<200 where !(await recovery.hasEnteredCommit()) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await recovery.hasEnteredCommit())
        let coordinator = controller.terminationCoordinator!
        var reply: Bool?
        let disposition = coordinator.applicationShouldTerminate {
            #expect(!editor.textView.isEditable)
            #expect(!coordinator.permitsApplicationCommands)
            reply = $0
        }
        #expect(disposition == .terminateLater)
        await recovery.releaseCommit()
        for _ in 0..<200 where reply == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(reply == true)
        #expect(controller.window?.isVisible == false)
        #expect(!editor.textView.isEditable)
        #expect(controller.hasDirtyDocuments)
        #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
    }

    @Test @MainActor func redCloseKeepsSameRegisteredWorkspaceForRepeatedReopen() async {
        let recovery = RoutingRecoveryStore()
        let (controller, workspace, editor, panels, _) = await makeController(decisions: [], recoveryStore: recovery)
        defer { controller.close() }
        dirty(editor, with: "reopen this workspace")
        let before = workspace.snapshot().tabs
        for _ in 0..<34 {
            controller.showWindow(nil)
            #expect(!controller.windowShouldClose(controller.window!))
            for _ in 0..<200 where controller.window?.isVisible == true { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(controller.window?.isVisible == false)
            #expect(controller.terminationCoordinator?.attachedWindowCount == 1)
            #expect(workspace.snapshot().tabs == before)
        }
        controller.performNewScratch()
        for _ in 0..<200 where workspace.snapshot().tabs.count == before.count { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.window?.isVisible == true)
        #expect(workspace.snapshot().tabs.count == before.count + 1)
        #expect(editor.snapshot(for: before[0].buffer.bufferID)?.text == "reopen this workspace")
        #expect(editor.textView.isEditable)
        #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
    }

    @Test @MainActor func redClosePreservesDirtySessionWithoutConfirmingOrResetting() async {
        let recovery = RoutingRecoveryStore()
        let (controller, workspace, editor, panels, _) = await makeController(
            decisions: [], recoveryStore: recovery, approvedWindowClose: { $0.windowController?.close() }
        )
        dirty(editor, with: "survives red close")
        let before = workspace.snapshot().tabs
        #expect(!controller.windowShouldClose(controller.window!))
        for _ in 0..<200 where controller.window != nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.window == nil)
        #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
        let (reopened, restored, restoredEditor, _, _) = await makeController(decisions: [], recoveryStore: recovery)
        defer { reopened.close() }
        #expect(restored.snapshot().tabs == before)
        #expect(restoredEditor.textView.string == "survives red close")
    }

    @Test @MainActor func sessionQuitJoinsLateWindowAndKeepsEarlierWindowLocked() async {
        let coordinator = ApplicationTerminationCoordinator()
        let firstStore = RoutingRecoveryStore()
        let (first, _, firstEditor, firstPanels, _) = await makeController(decisions: [], recoveryStore: firstStore, terminationCoordinator: coordinator)
        dirty(firstEditor, with: "first retained")
        await firstStore.blockCommit()
        var reply: Bool?
        #expect(coordinator.applicationShouldTerminate { reply = $0 } == .terminateLater)
        for _ in 0..<200 where !(await firstStore.hasEnteredCommit()) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await firstStore.hasEnteredCommit())
        #expect(reply == nil)
        let secondStore = RoutingRecoveryStore()
        let (second, _, secondEditor, secondPanels, _) = await makeController(decisions: [], recoveryStore: secondStore, terminationCoordinator: coordinator)
        defer { first.close(); second.close() }
        dirty(secondEditor, with: "late retained")
        await secondStore.blockCommit()
        await firstStore.releaseCommit()
        for _ in 0..<200 where !(await secondStore.hasEnteredCommit()) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await secondStore.hasEnteredCommit())
        #expect(!firstEditor.textView.isEditable && !secondEditor.textView.isEditable)
        #expect(reply == nil)
        await secondStore.releaseCommit()
        for _ in 0..<200 where reply == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(reply == true)
        #expect(first.hasDirtyDocuments && second.hasDirtyDocuments)
        #expect(firstPanels.decisionTabs.isEmpty && secondPanels.decisionTabs.isEmpty)
        #expect(firstPanels.allDecisionTabs.isEmpty && secondPanels.allDecisionTabs.isEmpty)
    }

    @Test @MainActor func sessionQuitWaitsForStartupAndNeverOverwritesFailedRecovery() async {
        for failsLoad in [false, true] {
            let recovery = RoutingRecoveryStore()
            let (seed, _, editor, _, _) = await makeController(decisions: [], recoveryStore: recovery)
            dirty(editor, with: "previous launch unsaved data")
            #expect(await seed.reviewDirtyDocumentsForTermination())
            seed.close()
            let before = await recovery.commitCount
            await recovery.blockLoad()
            if failsLoad { await recovery.setLoadError(.corrupt("injected load failure")) }
            let errors = RecoveryErrorPresenterSpy()
            let (controller, _, _, panels, _) = await makeController(decisions: [], errorPresenter: errors, recoveryStore: recovery, waitForStartup: false)
            let coordinator = controller.terminationCoordinator!
            var reply: Bool?
            #expect(coordinator.applicationShouldTerminate { reply = $0 } == .terminateLater)
            for _ in 0..<200 where !(await recovery.hasEnteredLoad()) { await Task.yield() }
            #expect(!(await controller.flushRecovery())) // focus-loss flush during startup
            #expect(reply == nil)
            #expect(await recovery.commitCount == before)
            await recovery.releaseLoad()
            for _ in 0..<200 where reply == nil { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(reply == !failsLoad)
            if failsLoad {
                #expect(!(await controller.flushRecovery()))
                #expect(await recovery.commitCount == before)
            }
            #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
            await recovery.setLoadError(nil)
            let stored = try? await recovery.loadLatest()
            #expect(stored?.archive.buffers.values.first?.utf8 == Data("previous launch unsaved data".utf8))
            controller.close()
        }
    }

    @Test @MainActor func explicitCloseAllUsesBulkDecisionAndQuitDoesNotRestoreDiscardedTabs() async {
        let recovery = RoutingRecoveryStore()
        let (controller, workspace, editor, panels, _) = await makeController(decisions: [], recoveryStore: recovery)
        dirty(editor, with: "discard first")
        _ = await workspace.addScratch()
        dirty(editor, with: "discard second")
        let oldIDs = Set(workspace.snapshot().tabs.map(\.id))
        panels.allDecision = .discard
        controller.performCloseAllTabs()
        for _ in 0..<200 where workspace.snapshot().tabs.contains(where: { oldIDs.contains($0.id) }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!workspace.snapshot().tabs.contains { oldIDs.contains($0.id) })
        #expect(panels.allDecisionTabs.map(\.count) == [2])
        #expect(panels.decisionTabs.isEmpty)
        #expect(await controller.reviewDirtyDocumentsForTermination())
        controller.close()
        let (reopened, restored, _, _, _) = await makeController(decisions: [], recoveryStore: recovery)
        defer { reopened.close() }
        #expect(!restored.snapshot().tabs.contains { oldIDs.contains($0.id) })
    }

    @Test @MainActor func terminationDiscardAllUsesOnePromptAcrossWindowsAndKeepsCleanTabs() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (first, firstWorkspace, firstEditor, firstPanels, _) = await makeController(decisions: [], terminationCoordinator: coordinator)
        let (second, secondWorkspace, secondEditor, secondPanels, _) = await makeController(decisions: [], terminationCoordinator: coordinator)
        defer { first.close(); second.close() }
        dirty(firstEditor, with: "first")
        _ = await firstWorkspace.addScratch()
        let cleanID = firstWorkspace.snapshot().tabs.first(where: \.isActive)!.id
        dirty(secondEditor, with: "second")
        firstPanels.allDecision = .discard
        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(approved)
        #expect(firstPanels.allDecisionTabs.map(\.count) == [2])
        #expect(secondPanels.allDecisionTabs.isEmpty)
        #expect(firstPanels.decisionTabs.isEmpty && secondPanels.decisionTabs.isEmpty)
        #expect(firstWorkspace.snapshot().tabs.map(\.id) == [cleanID])
        #expect(!secondWorkspace.snapshot().tabs.contains(where: { $0.isDirty }))
    }

    @Test @MainActor func terminationSaveAllSavesEveryUntitledDocument() async {
        let (controller, workspace, editor, panels, files) = await makeController(decisions: [])
        defer { controller.close() }
        dirty(editor, with: "first saved text")
        _ = await workspace.addScratch()
        dirty(editor, with: "second saved text")
        let firstURL = URL(fileURLWithPath: "/tmp/duckpad-bulk-first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/duckpad-bulk-second.txt")
        panels.saveURLs = [firstURL, secondURL]
        panels.allDecision = .save
        #expect(await controller.reviewDirtyDocumentsForTermination())
        #expect(panels.allDecisionTabs.map(\.count) == [2])
        #expect(panels.decisionTabs.isEmpty)
        #expect(panels.saveRequests == 2)
        #expect(workspace.snapshot().tabs.count == 2)
        #expect(!controller.hasDirtyDocuments)
        #expect(await files.text(at: firstURL) == "first saved text")
        #expect(await files.text(at: secondURL) == "second saved text")
    }

    @Test @MainActor func terminationSaveAllCancellationOrFailureStopsAndAsksAgainOnRetry() async {
        for failsWrite in [false, true] {
            let (controller, workspace, editor, panels, _) = await makeController(
                decisions: [],
                saveURL: failsWrite ? URL(fileURLWithPath: "/tmp/duckpad-bulk-failure.txt") : nil,
                writeError: failsWrite ? .io("injected bulk save failure") : nil
            )
            dirty(editor, with: "first")
            _ = await workspace.addScratch()
            dirty(editor, with: "second")
            panels.allDecision = .save
            #expect(!(await controller.reviewDirtyDocumentsForTermination()))
            #expect(workspace.snapshot().tabs.filter(\.isDirty).count == 2)
            #expect(panels.saveRequests == 1)
            #expect(panels.failures.count == (failsWrite ? 1 : 0))
            #expect(editor.textView.isEditable)
            panels.allDecision = .cancel
            #expect(!(await controller.reviewDirtyDocumentsForTermination()))
            #expect(panels.allDecisionTabs.count == 2)
            #expect(workspace.snapshot().tabs.filter(\.isDirty).count == 2)
            controller.close()
        }
    }

    @Test @MainActor func terminationBulkCancelClearsFailedSaveRetryIntent() async {
        let (controller, workspace, editor, panels, files) = await makeController(
            decisions: [.cancel],
            saveURL: URL(fileURLWithPath: "/tmp/duckpad-bulk-cancel-retry.txt"),
            writeError: .io("first attempt fails")
        )
        defer { controller.close() }
        dirty(editor, with: "first")
        _ = await workspace.addScratch()
        dirty(editor, with: "second")
        panels.allDecision = .save
        let coordinator = controller.terminationCoordinator!
        let first = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!first)
        #expect(panels.saveRequests == 1)
        await files.setWriteError(nil)
        panels.allDecision = .cancel
        let retry = await withCheckedContinuation { continuation in
            coordinator.installApplicationRetryHandler { [weak coordinator] in
                #expect(coordinator?.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
            }
            panels.retryLastFileFailure()
        }
        #expect(!retry)
        panels.allDecision = nil
        let next = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!next)
        #expect(panels.saveRequests == 1)
        #expect(panels.decisionTabs == [workspace.snapshot().tabs[0].title])
        #expect(workspace.snapshot().tabs.filter(\.isDirty).count == 2)
    }

    @Test @MainActor func terminationSaveAllKeepsEarlierSaveWhenLaterDestinationIsCancelled() async {
        let (controller, workspace, editor, panels, files) = await makeController(decisions: [])
        defer { controller.close() }
        dirty(editor, with: "saved first")
        _ = await workspace.addScratch()
        dirty(editor, with: "keep second")
        let url = URL(fileURLWithPath: "/tmp/duckpad-bulk-partial.txt")
        panels.saveURLs = [url]
        panels.allDecision = .save
        #expect(!(await controller.reviewDirtyDocumentsForTermination()))
        #expect(panels.saveRequests == 2)
        #expect(await files.text(at: url) == "saved first")
        #expect(workspace.snapshot().tabs.map(\.isDirty) == [false, true])
        #expect(editor.textView.string == "keep second")
        #expect(editor.textView.isEditable)
    }

    @Test @MainActor func terminationBulkCancelReopensEveryWindowWithoutDiscarding() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (first, _, firstEditor, firstPanels, _) = await makeController(decisions: [], terminationCoordinator: coordinator)
        let (second, _, secondEditor, secondPanels, _) = await makeController(decisions: [], terminationCoordinator: coordinator)
        defer { first.close(); second.close() }
        dirty(firstEditor, with: "first")
        dirty(secondEditor, with: "second")
        firstPanels.allDecision = .cancel
        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!approved)
        #expect(first.hasDirtyDocuments && second.hasDirtyDocuments)
        #expect(firstEditor.textView.isEditable && secondEditor.textView.isEditable)
        #expect(firstPanels.allDecisionTabs.count == 1)
        #expect(firstPanels.decisionTabs.isEmpty && secondPanels.decisionTabs.isEmpty)
        #expect(coordinator.permitsApplicationCommands)
    }

    @Test @MainActor func terminationDiscardAllDoesNotApproveEditsMadeDuringPrompt() async {
        let (controller, workspace, editor, panels, _) = await makeController(decisions: [.cancel])
        defer { controller.close() }
        dirty(editor, with: "first")
        _ = await workspace.addScratch()
        dirty(editor, with: "second")
        let changedID = workspace.snapshot().tabs.first(where: \.isActive)!.id
        panels.allDecision = .discard
        panels.onAllDecision = { dirty(editor, with: "changed during review") }
        #expect(!(await controller.reviewDirtyDocumentsForTermination()))
        #expect(panels.allDecisionTabs.count == 1)
        #expect(panels.decisionTabs.count == 1)
        #expect(workspace.snapshot().tabs.contains { $0.id == changedID && $0.isDirty })
        #expect(editor.textView.string == "changed during review")
    }

    @Test @MainActor func terminationDiscardAllDoesNotApproveWindowAttachedDuringPrompt() async {
        let coordinator = ApplicationTerminationCoordinator()
        let (first, workspace, editor, panels, _) = await makeController(decisions: [], terminationCoordinator: coordinator)
        dirty(editor, with: "first")
        _ = await workspace.addScratch()
        dirty(editor, with: "second")
        var late: DuckpadWindowController?
        var latePanels: PanelFake?
        panels.allDecision = .discard
        panels.onAllDecision = {
            let (controller, _, lateEditor, presenter, _) = await makeController(decisions: [.cancel], terminationCoordinator: coordinator)
            late = controller
            latePanels = presenter
            dirty(lateEditor, with: "new window needs review")
        }
        defer { first.close(); late?.close() }
        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!approved)
        #expect(panels.allDecisionTabs.count == 1)
        #expect(latePanels?.decisionTabs.count == 1)
        #expect(late?.hasDirtyDocuments == true)
    }

    @Test @MainActor func bulkQuitAlertHasSafeActionsAndBoundedDocumentList() async {
        let (controller, workspace, _, _, _) = await makeController(decisions: [])
        defer { controller.close() }
        for _ in 0..<6 { _ = await workspace.addScratch() }
        let tabs = workspace.snapshot().tabs
        let alert = NativeFilePanelAdapter.allDocumentsAlert(tabs, saveAvailable: true)
        #expect(alert.buttons.map(\.title) == ["Save All", "Cancel", "Discard All"])
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(alert.buttons[2].keyEquivalent != "\r")
        #expect(alert.informativeText.contains("…and 2 more."))
        let noSave = NativeFilePanelAdapter.allDocumentsAlert(tabs, saveAvailable: false)
        #expect(noSave.buttons.map(\.title) == ["Cancel", "Discard All"])
        #expect(noSave.buttons[0].keyEquivalent == "\u{1b}")
        #expect(noSave.buttons[1].keyEquivalent != "\r")
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
        #expect(firstPanels.decisionTabs.isEmpty)
        #expect(secondPanels.decisionTabs.isEmpty)
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
        #expect(secondPanels.decisionTabs.isEmpty)
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

        controller.close() // Explicit teardown still joins its recovery reset.
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
        #expect(latePanels.decisionTabs.isEmpty)
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

    @Test @MainActor func recoveryFailureCancelsQuitAndNextAttemptPreservesLatestEdits() async {
        let recovery = RoutingRecoveryStore()
        let errors = RecoveryErrorPresenterSpy()
        let (controller, workspace, editor, panels, _) = await makeController(
            decisions: [], errorPresenter: errors, recoveryStore: recovery
        )
        defer { controller.close() }
        dirty(editor, with: "keep original")
        await recovery.setCommitError(.unavailable("recovery disk unavailable"))
        let coordinator = controller.terminationCoordinator!
        let denied = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(!denied)
        #expect(editor.textView.isEditable)
        #expect(controller.hasDirtyDocuments)
        #expect(!errors.failures.isEmpty)
        #expect(panels.decisionTabs.isEmpty && panels.allDecisionTabs.isEmpty)
        #expect(panels.saveRequests == 0)
        await workspace.waitForPendingPersistence()
        dirty(editor, with: "newest unsaved content 🙂")
        await recovery.setCommitError(nil)
        let approved = await withCheckedContinuation { continuation in
            #expect(coordinator.applicationShouldTerminate { continuation.resume(returning: $0) } == .terminateLater)
        }
        #expect(approved)
        #expect(controller.hasDirtyDocuments)
        let archive = try? await recovery.loadLatest()
        #expect(archive?.archive.buffers.values.first?.utf8 == Data("newest unsaved content 🙂".utf8))
        #expect(panels.saveRequests == 0)
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

@Test(arguments: ["same", "new", "cancel", "edit", "conflict", "reload", "deniedAgain", "missing"])
@MainActor func savingReauthorizesWithoutReloadingOrLosingEdits(scenario: String) async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let source = URL(fileURLWithPath: "/tmp/duckpad-reauthorize-source.note")
    let destination = URL(fileURLWithPath: "/tmp/duckpad-reauthorize-new.note")
    await files.seed("original", at: source)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.openURL = source
    panels.saveAccessURL = scenario == "cancel" ? nil : (["new", "missing"].contains(scenario) ? destination : source)
    let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
        editorView: editor.scrollView, fileUseCase: useCase, filePanels: panels,
        fileConflictPresenter: panels, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await controller.routeOpenFile()
    editor.textView.selectAll(nil)
    editor.textView.insertText("edited 한글", replacementRange: editor.textView.selectedRange())
    let context = try #require(workspace.activeFileContext())
    await files.setWriteError(scenario == "missing" ? .notFound(source.path) : .permissionDenied(source.path))
    if scenario == "deniedAgain" { await files.setRenewalError(.permissionDenied(source.path)) }
    if scenario == "reload" { panels.conflictResolutions = [.reload] }
    panels.onSaveAccess = {
        if scenario == "edit" { editor.textView.insertText(" later", replacementRange: editor.textView.selectedRange()) }
        if ["conflict", "reload"].contains(scenario) { await files.seed("external", at: source) }
    }
    await controller.routeSaveFile()
    #expect(panels.saveAccessRequests == [source])
    #expect(editor.textView.string == (scenario == "edit" ? "edited 한글 later" : (scenario == "reload" ? "external" : "edited 한글")))
    #expect(workspace.activeFileContext()?.buffer.bufferID == context.buffer.bufferID)
    let succeeds = ["same", "new", "missing", "reload"].contains(scenario)
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.isDirty == !succeeds)
    #expect(await files.renewedPaths == (["cancel", "edit"].contains(scenario) ? [] : [panels.saveAccessURL!.path]))
    #expect(panels.failures.count == (scenario == "deniedAgain" ? 1 : 0))
    if succeeds {
        #expect(await files.text(at: panels.saveAccessURL!) == (scenario == "reload" ? "external" : "edited 한글"))
        #expect(workspace.activeFileContext()?.binding?.canonicalPath == panels.saveAccessURL!.path)
        #expect(workspace.activeFileContext()?.binding?.securityScopedBookmark == Data("renewed-grant".utf8))
    }
    if scenario != "same" { #expect(await files.text(at: source) == (["conflict", "reload"].contains(scenario) ? "external" : "original")) }
}

@Test(arguments: ["all", "close", "copy"])
@MainActor func saveAccessRecoveryWorksForBatchCloseAndCopy(action: String) async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    let editor = TextViewEditorAdapter()
    let files = RoutingFileStore()
    let source = URL(fileURLWithPath: "/tmp/duckpad-access-command.note")
    let copy = URL(fileURLWithPath: "/tmp/duckpad-access-copy.note")
    let target = action == "copy" ? copy : source
    await files.seed("original", at: source)
    let useCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
    let panels = PanelFake()
    panels.openURL = source
    panels.saveURL = copy
    panels.saveAccessURL = target
    panels.decisions = [.save]
    let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
        editorView: editor.scrollView, fileUseCase: useCase, filePanels: panels,
        fileConflictPresenter: panels, dirtyDecisionPresenter: panels, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await controller.routeOpenFile()
    editor.textView.selectAll(nil)
    editor.textView.insertText("retained edits", replacementRange: editor.textView.selectedRange())
    let context = try #require(workspace.activeFileContext())
    await files.setWriteError(.permissionDenied(target.path))
    switch action {
    case "all": controller.performSaveAll()
    case "close": controller.performCloseActiveTab()
    default: controller.performSaveCopyAs()
    }
    for _ in 0..<400 {
        let written = await files.text(at: target) == "retained edits"
        let tab = workspace.snapshot().tabs.first(where: { $0.id == context.tabID })
        if written && (action == "copy" || (action == "close" ? tab == nil : tab?.isDirty == false)) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await files.text(at: target) == "retained edits")
    #expect(panels.saveAccessRequests == [target])
    #expect(panels.failures.isEmpty)
    let tab = workspace.snapshot().tabs.first(where: { $0.id == context.tabID })
    if action == "close" { #expect(tab == nil) }
    if action == "all" { #expect(tab?.isDirty == false) }
    if action == "copy" {
        #expect(tab?.isDirty == true)
        #expect(workspace.activeFileContext()?.binding == context.binding)
        #expect(await files.text(at: source) == "original")
    }
}

@Test @MainActor func fileDialogDirectoryFollowsActiveBindingOnlyWhenEnabled() async {
    let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
    _ = await workspace.start()
    let panels = NativeFilePanelAdapter()
    let controller = DuckpadWindowController(workspace: workspace, filePanels: panels, automaticallyStarts: false)
    defer { controller.close() }
    controller.applyPreferences(AppSettings(fileDialogFollowsDocument: true))
    #expect(panels.preferredFileDirectory?() == nil)
    let path = "/tmp/duckpad-folder/example.txt"
    let identity = FileIdentity(canonicalPath: path, device: 1, inode: 2, byteCount: 0, modifiedNanoseconds: 0, contentToken: "test")
    _ = await workspace.addOpenedFile(binding: FileBinding(canonicalPath: path, encoding: .utf8, byteOrderMark: .absent, lineEnding: .lf, observedIdentity: identity), title: "example.txt")
    #expect(panels.preferredFileDirectory?()?.path == "/tmp/duckpad-folder")
    controller.applyPreferences(.defaults)
    #expect(panels.preferredFileDirectory?() == nil)
}
