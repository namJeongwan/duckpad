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
    var decisions: [CloseDecision] = []
    var blocksDecisions = false
    private(set) var decisionTabs: [String] = []
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { openRequests += 1; return openURL }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? { saveRequests += 1; return saveURL }
    func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution { .cancel }
    func presentFileFailure(_ failure: FileOperationFailure, attachedTo window: NSWindow?) { failures.append(failure) }
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

@Suite(.serialized)
struct FileLifecycleTests {
    @MainActor
    private func makeController(
        decisions: [CloseDecision],
        saveURL: URL? = nil,
        writeError: TextFileStoreError? = nil,
        blocksDecisions: Bool = false,
        approvedWindowClose: (@MainActor (NSWindow) -> Void)? = nil
    ) async -> (DuckpadWindowController, ScratchWorkspaceUseCase, TextViewEditorAdapter, PanelFake, RoutingFileStore) {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: RoutingSessionStore())
        let editor = TextViewEditorAdapter()
        let files = RoutingFileStore()
        await files.setWriteError(writeError)
        let fileUseCase = FileDocumentUseCase(workspace: workspace, editor: editor, store: files)
        let panels = PanelFake()
        panels.decisions = decisions
        panels.blocksDecisions = blocksDecisions
        panels.saveURL = saveURL
        let terminationCoordinator = ApplicationTerminationCoordinator()
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: editor,
            editorView: editor.scrollView,
            fileUseCase: fileUseCase,
            filePanels: panels,
            fileConflictPresenter: panels,
            dirtyDecisionPresenter: panels,
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
        let (failureController, failureWorkspace, failureEditor, failurePanels, _) = await makeController(
            decisions: [.save],
            saveURL: URL(fileURLWithPath: "/tmp/duckpad-terminate-failure.txt"),
            writeError: failure
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
        failureController.close()
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
}
