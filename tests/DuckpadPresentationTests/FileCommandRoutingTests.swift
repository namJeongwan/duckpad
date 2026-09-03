import AppKit
import DuckpadApplication
import DuckpadDomain
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

private actor RoutingRecoveryStore: RecoveryStore {
    private var stored: StoredRecoveryArchive?
    private var loadError: SessionStoreError?
    private(set) var commitCount = 0
    func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? {
        if let loadError { throw loadError }
        return stored
    }
    func commit(_ archive: RecoveryArchive, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        stored = StoredRecoveryArchive(archive: archive, generation: generation)
        commitCount += 1
        return .committed
    }
    func reset() async throws(SessionStoreError) { stored = nil }
    func setLoadError(_ error: SessionStoreError?) { loadError = error }
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
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { url.standardizedFileURL }
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
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
    func setWriteError(_ error: TextFileStoreError?) { forcedWriteError = error }
}

@MainActor
private final class PanelFake: FilePanelPresenting, FileConflictPresenting, DirtyDocumentDecisionPresenting {
    var openURL: URL?
    var saveURL: URL?
    private(set) var openRequests = 0
    private(set) var saveRequests = 0
    private(set) var failures: [FileOperationFailure] = []
    private(set) var fileFailureRetries: [@MainActor () -> Void] = []
    var decisions: [CloseDecision] = []
    var blocksDecisions = false
    private(set) var decisionTabs: [String] = []
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { openRequests += 1; return openURL }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? { saveRequests += 1; return saveURL }
    func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution { .cancel }
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
        let terminationCoordinator = ApplicationTerminationCoordinator()
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

        panels.releaseDecisions()
        #expect(await review.value == false)
        #expect(controller.validateMenuItem(wordWrap))
        #expect(wordWrap.state == .on)
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
