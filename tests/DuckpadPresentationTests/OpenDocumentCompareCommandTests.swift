import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

private actor CompareSessionStore: SessionStore {
    private var session: ScratchSession?
    private var generation = PersistenceGeneration(rawValue: 0)

    init(session: ScratchSession? = nil) { self.session = session }

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: generation) }
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        guard generation > self.generation else { return .superseded(durableGeneration: self.generation) }
        self.session = session
        self.generation = generation
        return .committed
    }
}

@MainActor
private final class ComparePresenterSpy: OpenDocumentComparePresenting {
    var selectedTabID: TabID?
    private(set) var source: TabSnapshot?
    private(set) var candidates: [TabSnapshot] = []
    private(set) var presented: [OpenDocumentCompareContent] = []
    private(set) var failures: [OpenDocumentComparison.Error] = []
    private(set) var cancellationCount = 0
    var blockPresentation = false
    private var presentationEntered = false
    private var presentationInvocationCount = 0
    var holdCancellationDismissal = false
    var releaseCancellationDismissal = false
    private var cancellationObserved = false
    private var cancelledPresentationCount = 0

    func chooseTarget(
        source: TabSnapshot,
        candidates: [TabSnapshot],
        attachedTo window: NSWindow?
    ) async -> TabID? {
        self.source = source
        self.candidates = candidates
        return selectedTabID
    }

    func present(
        _ content: OpenDocumentCompareContent,
        attachedTo window: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        presentationEntered = true
        presentationInvocationCount += 1
        while blockPresentation {
            if Task.isCancelled {
                cancellationObserved = true
                while holdCancellationDismissal, !releaseCancellationDismissal { await Task.yield() }
                cancelledPresentationCount += 1
                throw OpenDocumentComparison.Error.cancelled
            }
            await Task.yield()
        }
        guard !Task.isCancelled, isCurrent() else { throw OpenDocumentComparison.Error.cancelled }
        presented.append(content)
    }

    func presentFailure(_ error: OpenDocumentComparison.Error, attachedTo window: NSWindow?) {
        failures.append(error)
    }

    func cancelOutstandingComparisons() {
        cancellationCount += 1
    }

    func waitUntilPresentationEntered() async {
        while !presentationEntered { await Task.yield() }
    }

    func waitUntilCancellationObserved() async {
        while !cancellationObserved { await Task.yield() }
    }

    func waitForPresentationInvocationCount(_ count: Int) async {
        while presentationInvocationCount < count { await Task.yield() }
    }

    func waitForCancelledPresentationCount(_ count: Int) async {
        while cancelledPresentationCount < count { await Task.yield() }
    }
}

@MainActor
private func makeCompareController() async -> (DuckpadWindowController, ScratchWorkspaceUseCase, TextViewEditorAdapter, ComparePresenterSpy) {
    let workspace = ScratchWorkspaceUseCase(store: CompareSessionStore())
    let editor = TextViewEditorAdapter()
    let presenter = ComparePresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: editor.scrollView,
        openDocumentComparePresenter: presenter,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()
    editor.textView.insertText("left", replacementRange: editor.textView.selectedRange())
    _ = await workspace.addScratch()
    editor.textView.insertText("right", replacementRange: editor.textView.selectedRange())
    await workspace.waitForPendingPersistence()
    presenter.selectedTabID = workspace.snapshot().tabs.first?.id
    return (controller, workspace, editor, presenter)
}

@Test @MainActor func compareCommandIsDisabledUntilTwoOpenTabsExist() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: CompareSessionStore())
    let presenter = ComparePresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        openDocumentComparePresenter: presenter,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let item = NSMenuItem(title: "Compare", action: #selector(DuckpadWindowController.performCompareWithOpenDocument(_:)), keyEquivalent: "")

    #expect(controller.validateMenuItem(item) == false)
    _ = await workspace.addScratch()
    #expect(controller.validateMenuItem(item))
}

@Test @MainActor func compareCommandCapturesWithoutActivatingTargetAndRestoresFocus() async {
    _ = NSApplication.shared
    let (controller, workspace, editor, presenter) = await makeCompareController()
    defer { controller.close() }
    controller.showAndFocus()
    let sourceID = workspace.snapshot().tabs.first(where: \.isActive)?.id

    controller.performCompareWithOpenDocument(nil)
    await controller.waitForOpenDocumentCompare()

    #expect(presenter.source?.id == sourceID)
    #expect(presenter.candidates.map(\.id).contains(sourceID!) == false)
    #expect(presenter.presented.count == 1)
    #expect(presenter.presented[0].leftText == "right")
    #expect(presenter.presented[0].rightText == "left")
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == sourceID)
    #expect(controller.window?.firstResponder === editor.textView)
}

@Test @MainActor func newerCompareRequestCancelsOlderRequest() async {
    _ = NSApplication.shared
    let (controller, _, _, presenter) = await makeCompareController()
    defer { controller.close() }
    presenter.blockPresentation = true
    controller.performCompareWithOpenDocument(nil)
    await presenter.waitUntilPresentationEntered()

    controller.performCompareWithOpenDocument(nil)
    presenter.blockPresentation = false
    await controller.waitForOpenDocumentCompare()

    #expect(presenter.cancellationCount >= 2)
    #expect(presenter.presented.count == 1)
}

@Test @MainActor func revisionChangeSuppressesStaleCompareResult() async {
    _ = NSApplication.shared
    let (controller, workspace, _, presenter) = await makeCompareController()
    defer { controller.close() }
    presenter.blockPresentation = true
    controller.performCompareWithOpenDocument(nil)
    await presenter.waitUntilPresentationEntered()

    let activeBuffer = try! #require(workspace.snapshot().activeBuffer)
    _ = workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: activeBuffer.bufferID,
        expectedRevision: activeBuffer.revision,
        range: TextEditRange(location: 0, length: 0),
        replacement: " changed"
    ))
    presenter.blockPresentation = false
    await controller.waitForOpenDocumentCompare()

    #expect(presenter.presented.isEmpty)
}

@Test @MainActor func staleCompareRestoresFocusOnlyAfterDismissalFinishes() async {
    _ = NSApplication.shared
    let (controller, workspace, editor, presenter) = await makeCompareController()
    defer { controller.close() }
    controller.showAndFocus()
    let temporary = NSTextField(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    controller.window?.contentView?.addSubview(temporary)
    presenter.blockPresentation = true
    presenter.holdCancellationDismissal = true
    controller.performCompareWithOpenDocument(nil)
    await presenter.waitUntilPresentationEntered()
    controller.window?.makeFirstResponder(temporary)
    let temporaryResponder = controller.window?.firstResponder

    let activeBuffer = try! #require(workspace.snapshot().activeBuffer)
    _ = workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: activeBuffer.bufferID,
        expectedRevision: activeBuffer.revision,
        range: TextEditRange(location: 0, length: 0),
        replacement: " changed"
    ))
    await presenter.waitUntilCancellationObserved()

    #expect(controller.window?.firstResponder === temporaryResponder)
    #expect(controller.window?.firstResponder !== editor.textView)
    presenter.releaseCancellationDismissal = true
    await controller.waitForOpenDocumentCompare()
    #expect(controller.window?.firstResponder === editor.textView)
}

@Test @MainActor func supersededCompareNeverStealsFocusFromNewerRequest() async {
    _ = NSApplication.shared
    let (controller, _, editor, presenter) = await makeCompareController()
    defer { controller.close() }
    controller.showAndFocus()
    let temporary = NSTextField(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    controller.window?.contentView?.addSubview(temporary)
    presenter.blockPresentation = true
    presenter.holdCancellationDismissal = true
    controller.performCompareWithOpenDocument(nil)
    await presenter.waitForPresentationInvocationCount(1)
    controller.window?.makeFirstResponder(temporary)
    let temporaryResponder = controller.window?.firstResponder

    controller.performCompareWithOpenDocument(nil)
    await presenter.waitForPresentationInvocationCount(2)
    presenter.releaseCancellationDismissal = true
    await presenter.waitForCancelledPresentationCount(1)

    #expect(controller.window?.firstResponder === temporaryResponder)
    #expect(controller.window?.firstResponder !== editor.textView)
    presenter.blockPresentation = false
    await controller.waitForOpenDocumentCompare()
    #expect(controller.window?.firstResponder === editor.textView)
}

@Test @MainActor func missingPickerSelectionPresentsTypedFailureWithoutChangingActiveTab() async {
    _ = NSApplication.shared
    let (controller, workspace, _, presenter) = await makeCompareController()
    defer { controller.close() }
    let activeID = workspace.snapshot().tabs.first(where: \.isActive)?.id
    let missingID = TabID()
    presenter.selectedTabID = missingID

    controller.performCompareWithOpenDocument(nil)
    await controller.waitForOpenDocumentCompare()

    #expect(presenter.presented.isEmpty)
    #expect(presenter.failures == [.missingTab(missingID)])
    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == activeID)
}

@Test @MainActor func controllerTeardownCancelsOutstandingComparison() async {
    _ = NSApplication.shared
    let (controller, _, _, presenter) = await makeCompareController()
    presenter.blockPresentation = true
    controller.performCompareWithOpenDocument(nil)
    await presenter.waitUntilPresentationEntered()

    controller.close()

    #expect(presenter.cancellationCount >= 2)
}

@Test @MainActor func nativeFileConflictCompareUsesSharedAlignedRenderer() async {
    let presenter = ComparePresenterSpy()
    let panels = NativeFilePanelAdapter(openDocumentComparePresenter: presenter)
    let identity = FileIdentity(canonicalPath: "/tmp/a.txt", device: 1, inode: 2, byteCount: 8, modifiedNanoseconds: 3, contentToken: "v")
    let comparison = ExternalFileComparison(
        tabID: TabID(),
        path: "/tmp/a.txt",
        localText: "mine",
        externalText: "theirs",
        localRevision: 4,
        externalIdentity: identity
    )

    await panels.presentExternalComparison(comparison, attachedTo: nil)

    #expect(presenter.presented.first?.leftText == "mine")
    #expect(presenter.presented.first?.rightText == "theirs")
    #expect(presenter.presented.first?.leftTitle == "Duckpad — revision 4")
    #expect(presenter.presented.first?.rightTitle == "On Disk")
}

@Test @MainActor func toolsMenuContainsValidatedCompareCommand() async {
    let (controller, _, _, _) = await makeCompareController()
    defer { controller.close() }
    let menu = DuckpadMainMenuFactory.make(target: controller)
    let tools = menu.items.first(where: { $0.submenu?.title == "Tools" })?.submenu
    let item = tools?.items.first(where: { $0.title == "Compare with Open Document…" })

    #expect(item?.action == #selector(DuckpadWindowController.performCompareWithOpenDocument(_:)))
    #expect(item?.target === controller)
    #expect(item.map(controller.validateMenuItem) == true)
}
