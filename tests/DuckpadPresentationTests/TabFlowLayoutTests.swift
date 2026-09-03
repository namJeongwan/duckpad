import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

private actor PresentationStore: SessionStore {
    private var session: ScratchSession?
    private var generation = PersistenceGeneration(rawValue: 0)
    private var failure: SessionStoreError?
    private var failLoad = false
    private var commitAttempts = 0
    init(session: ScratchSession? = nil) { self.session = session }
    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        if failLoad, let failure { throw failure }
        return session.map { StoredSession(session: $0, generation: generation) }
    }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        commitAttempts += 1
        if let failure { throw failure }
        guard generation > self.generation else { return .superseded(durableGeneration: self.generation) }
        self.session = session
        self.generation = generation
        return .committed
    }
    func setFailure(_ failure: SessionStoreError?, forLoad: Bool = false) {
        self.failure = failure
        failLoad = forLoad
    }
    func attempts() -> Int { commitAttempts }
}

private actor DelayedPresentationStore: SessionStore {
    private var session: ScratchSession?
    private var blocked = true
    private var entered = false
    private var generation = PersistenceGeneration(rawValue: 0)

    init(session: ScratchSession?) { self.session = session }

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        entered = true
        while blocked { await Task.yield() }
        return session.map { StoredSession(session: $0, generation: generation) }
    }

    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        guard generation > self.generation else { return .superseded(durableGeneration: self.generation) }
        self.session = session
        self.generation = generation
        return .committed
    }

    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { blocked = false }
}

@MainActor
private final class ErrorPresenterSpy: PersistenceErrorPresenting {
    private(set) var failures: [PersistenceFailure] = []
    private(set) var retries: [() -> Void] = []

    func present(failure: PersistenceFailure, retry: @escaping @MainActor () -> Void) {
        failures.append(failure)
        retries.append(retry)
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

@MainActor
private final class HostedLanguageEditorFake: LanguageEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var supportedLexers: Set<String> = []
    var prefix = Data()
    var configurations: [EditorLanguageConfiguration] = []
    private(set) var mutationCount = 0
    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]

    var activeLanguageID: LanguageID { configurations.last?.languageID ?? .plainText }
    var isLanguageStylingFallback: Bool { false }
    var activeDocumentByteLength: Int {
        guard let activeBuffer else { return 0 }
        return snapshots[activeBuffer.bufferID]?.text.utf8.count ?? 0
    }

    func display(_ buffer: EditorBufferDescriptor) {
        activeBuffer = buffer
        if snapshots[buffer.bufferID] == nil {
            snapshots[buffer.bufferID] = EditorTextSnapshot(
                bufferID: buffer.bufferID,
                revision: buffer.revision,
                text: "preserved 🦆 text"
            )
        }
    }
    func install(_ snapshot: EditorTextSnapshot) { snapshots[snapshot.bufferID] = snapshot }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { snapshots[bufferID] }
    func retire(bufferID: BufferID) { snapshots.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func detectionPrefix(maximumBytes: Int) -> Data { Data(prefix.prefix(maximumBytes)) }
    func supportsLexer(named name: String) -> Bool { supportedLexers.contains(name) }
    func applyLanguage(_ configuration: EditorLanguageConfiguration) -> Bool {
        configurations.append(configuration)
        return true
    }
    func applyTheme(_ palette: EditorThemePalette) {}
    func toggleLineComment(prefix: String) -> EditorEditOutcome {
        mutationCount += 1
        return .rejected(currentRevision: activeBuffer?.revision ?? 0)
    }
}

@MainActor
private func makeAndCloseController(
    workspace: ScratchWorkspaceUseCase
) -> (WeakBox<DuckpadWindowController>, WeakBox<NSWindow>) {
    var result: (WeakBox<DuckpadWindowController>, WeakBox<NSWindow>)!
    autoreleasepool {
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        result = (WeakBox(controller), WeakBox(controller.window))
        controller.close()
    }
    return result
}

private func makeTabs(count: Int, activeIndex: Int, dirtyIndex: Int? = nil) -> [TabSnapshot] {
    (0..<count).map { index in
        TabSnapshot(
            id: TabID(),
            title: "new \(index + 1)",
            isActive: index == activeIndex,
            isDirty: index == dirtyIndex,
            isPinned: index == 0,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: index == dirtyIndex ? 1 : 0)
        )
    }
}

@MainActor
private func hostStrip(
    width: CGFloat,
    height: CGFloat,
    tabs: [TabSnapshot]
) -> (NSWindow, NSView, MultilineTabStripView) {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let strip = MultilineTabStripView(frame: .zero)
    root.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        strip.topAnchor.constraint(equalTo: root.topAnchor),
    ])
    window.contentView = root
    strip.apply(tabs: tabs)
    root.layoutSubtreeIfNeeded()
    strip.layoutSubtreeIfNeeded()
    strip.hostedCollectionView.layoutSubtreeIfNeeded()
    return (window, root, strip)
}

@MainActor
private func descendantButtons(of view: NSView) -> [NSButton] {
    let direct = view.subviews.compactMap { $0 as? NSButton }
    return direct + view.subviews.flatMap(descendantButtons)
}

@MainActor
private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
        if item.title == title { return item }
        if let submenu = item.submenu, let found = menuItem(title, in: submenu) { return found }
    }
    return nil
}

@Test func tabsWrapAcrossRowsWhilePreservingOrder() {
    let engine = TabFlowLayoutEngine(
        rowHeight: 30,
        horizontalSpacing: 4,
        verticalSpacing: 5,
        insets: .init(top: 2, left: 2, bottom: 2, right: 2),
        minimumItemWidth: 80,
        maximumItemWidth: 200
    )
    let result = engine.layout(itemWidths: [100, 100, 100], containerWidth: 230)
    #expect(result.frames.count == 3)
    #expect(result.rowIndices == [0, 0, 1])
    #expect(result.rowCount == 2)
    #expect(result.contentHeight == 69)
}

@Test func fiftyAndFiveHundredTabsRemainCappedInNarrowWorkspace() {
    let engine = TabFlowLayoutEngine()
    let policy = TabStripViewportPolicy(maximumRows: 4, maximumWorkspaceFraction: 0.34)
    for count in [50, 500] {
        let result = engine.layout(itemWidths: Array(repeating: 120, count: count), containerWidth: 250)
        let viewport = policy.height(
            contentHeight: result.contentHeight,
            workspaceHeight: 300,
            engine: engine
        )
        #expect(result.rowCount >= count / 3)
        #expect(viewport <= 300 * 0.34)
        #expect(viewport < result.contentHeight)
    }
}

@Test func itemWidthsAreClampedEvenAtNarrowBoundary() {
    let engine = TabFlowLayoutEngine(minimumItemWidth: 90, maximumItemWidth: 180)
    let result = engine.layout(itemWidths: [20, 500], containerWidth: 95)
    #expect(result.frames.map(\.width) == [90, 90])
    #expect(result.rowCount == 2)
}

@Test @MainActor func visibleAttributeQueriesInspectOnlyIntersectingRowsAtScale() {
    for count in [500, 5_000] {
        let layout = MultilineTabCollectionLayout()
        let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        collection.collectionViewLayout = layout
        layout.itemWidths = Array(repeating: 120, count: count)
        layout.prepare()
        let target = count / 2
        guard let item = layout.layoutAttributesForItem(
            at: IndexPath(item: target, section: 0)
        ) else {
            Issue.record("layout did not cache target item")
            continue
        }
        let rect = NSRect(x: 0, y: item.frame.minY, width: 500, height: layout.engine.rowHeight)
        let visible = layout.layoutAttributesForElements(in: rect)

        #expect(!visible.isEmpty)
        #expect(layout.rowCount > 1)
        #expect(layout.lastElementsQueryVisitedRows <= 2)
        #expect(layout.lastElementsQueryInspectedItems <= 10)
        #expect(layout.lastElementsQueryInspectedItems < count / 10)
    }
}

@Test func appKitBeforeDropIndexConvertsToStableFinalIndexInEveryDirection() {
    #expect(TabDropDestination.finalIndex(sourceIndex: 1, insertionIndex: 4, itemCount: 5) == 3)
    #expect(TabDropDestination.finalIndex(sourceIndex: 4, insertionIndex: 1, itemCount: 5) == 1)
    #expect(TabDropDestination.finalIndex(sourceIndex: 0, insertionIndex: 5, itemCount: 5) == 4)
    #expect(TabDropDestination.finalIndex(sourceIndex: 3, insertionIndex: 0, itemCount: 5) == 0)
    #expect(TabDropDestination.finalIndex(sourceIndex: 9, insertionIndex: 0, itemCount: 5) == nil)
}

@Suite(.serialized)
struct AppKitHostedTests {
@Test @MainActor func unavailableRecoveredLanguageIsVisibleAndAutoResetIsExplicit() async throws {
    let missingID = LanguageID(rawValue: "removed-language")
    var restored = ScratchSession()
    let tabID = restored.addUntitled()
    try restored.setLanguageOverride(.manual(missingID), for: tabID)
    let store = PresentationStore(session: restored)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let editor = HostedLanguageEditorFake()
    editor.supportedLexers = ["null", "python"]
    editor.prefix = Data("#!/usr/bin/env python3\nprint('duck')".utf8)
    let registry = try LanguageRegistry(definitions: [
        LanguageDefinition(
            id: .plainText, displayName: "Plain Text", group: "Text",
            lexerName: "null", supportTier: .plain
        ),
        LanguageDefinition(
            id: LanguageID(rawValue: "python"), displayName: "Python", group: "Code",
            lexerName: "python", supportTier: .keywordComplete,
            keywordLists: ["def return"], extensions: ["py"], shebangTokens: ["python3"]
        ),
    ])
    let service = LanguageWorkspaceUseCase(
        registry: registry,
        workspace: workspace,
        editor: editor
    )
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: NSView(frame: .zero),
        languageUseCase: service,
        automaticallyStarts: false
    )
    defer { controller.close() }

    controller.start()
    await controller.waitForStartup()
    let beforeSession = workspace.recoverySession()
    let beforeBuffer = workspace.snapshot().activeBuffer
    let beforeText = try #require(beforeBuffer.flatMap { editor.snapshot(for: $0.bufferID) })

    #expect(service.state == .unavailableManual(requestedID: missingID, fallback: .plainText))
    #expect(editor.configurations.last?.lexerName == "null")
    #expect(controller.languageStatusSmokeState().isWarning)
    #expect(controller.languageStatusSmokeState().text.contains("removed-language"))
    #expect(controller.languageStatusSmokeState().text.contains("using Plain Text"))
    #expect(workspace.recoverySession() == beforeSession)
    #expect(workspace.snapshot().activeBuffer == beforeBuffer)
    #expect(editor.snapshot(for: beforeText.bufferID) == beforeText)
    #expect(editor.mutationCount == 0)

    let menu = DuckpadMainMenuFactory.make(target: controller)
    #expect(menuItem("Auto", in: menu)?.action == #selector(DuckpadWindowController.performAutomaticLanguage(_:)))
    #expect(menuItem("Python", in: menu)?.representedObject as? String == "python")
    #expect(menuItem("removed-language", in: menu) == nil)

    #expect(await service.setOverride(.automatic) == .applied(.saved))
    guard case .ready(let detection, _) = service.state else {
        Issue.record("explicit Auto did not clear the unavailable warning")
        return
    }
    #expect(detection.languageID.rawValue == "python")
    #expect(!controller.languageStatusSmokeState().isWarning)
    #expect(controller.languageStatusSmokeState().text == "Python")
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .automatic)
    #expect(workspace.snapshot().activeBuffer?.revision == beforeBuffer?.revision)
    #expect(editor.snapshot(for: beforeText.bufferID) == beforeText)
    #expect(editor.mutationCount == 0)
}

@Test @MainActor func failedActivationRestoresAuthoritativeSelectionWithoutRecursion() async {
    let store = PresentationStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    let presenter = ErrorPresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        errorPresenter: presenter,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    _ = await workspace.addScratch()
    let ids = workspace.snapshot().tabs.map(\.id)
    _ = await workspace.activate(tabID: ids[0])
    controller.editor.textView.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0),
        with: "authoritative A"
    )
    for _ in 0..<1_000 where workspace.snapshot().tabs.first(where: { $0.id == ids[0] })?.buffer.revision == 0 {
        await Task.yield()
    }
    await workspace.waitForPendingPersistence()
    let before = await store.attempts()
    await store.setFailure(.unavailable("activation persistence offline"))

    let requested = IndexPath(item: 1, section: 0)
    controller.tabStrip.hostedCollectionView.selectionIndexPaths = [requested]
    controller.tabStrip.collectionView(
        controller.tabStrip.hostedCollectionView,
        didSelectItemsAt: [requested]
    )
    for _ in 0..<1_000 where presenter.failures.isEmpty { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }

    #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == ids[0])
    #expect(controller.editor.textView.string == "authoritative A")
    #expect(controller.tabStrip.hostedCollectionView.selectionIndexPaths == [
        IndexPath(item: 0, section: 0),
    ])
    #expect(controller.tabStrip.selectedTabIsVisible)
    #expect(await store.attempts() == before + 1)
    let activeItem = controller.tabStrip.hostedCollectionView.item(
        at: IndexPath(item: 0, section: 0)
    )
    #expect((activeItem?.view.accessibilityValue() as? String)?.contains("selected") == true)
}

@Test @MainActor func mainMenuPublishesNativeTabSelectorsAndExactShortcuts() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let menu = DuckpadMainMenuFactory.make(target: controller)

    let close = menuItem("Close Tab", in: menu)
    #expect(close?.action == #selector(DuckpadWindowController.performCloseActiveTab(_:)))
    #expect(close?.keyEquivalent == "w")
    #expect(close?.keyEquivalentModifierMask == [.command])

    let mru = menuItem("Last Used Tab", in: menu)
    let reverseMRU = menuItem("Previous in Tab History", in: menu)
    #expect(mru?.action == #selector(DuckpadWindowController.performLastUsedTab(_:)))
    #expect(mru?.keyEquivalent == "\t")
    #expect(mru?.keyEquivalentModifierMask == [.control])
    #expect(reverseMRU?.action == #selector(DuckpadWindowController.performLastUsedTab(_:)))
    #expect(reverseMRU?.keyEquivalentModifierMask == [.control, .shift])

    let moveLeft = menuItem("Move Tab Left", in: menu)
    let moveRight = menuItem("Move Tab Right", in: menu)
    #expect(moveLeft?.action == #selector(DuckpadWindowController.performMoveActiveTabLeft(_:)))
    #expect(moveLeft?.keyEquivalent == "[")
    #expect(moveLeft?.keyEquivalentModifierMask == [.command, .shift])
    #expect(moveRight?.action == #selector(DuckpadWindowController.performMoveActiveTabRight(_:)))
    #expect(moveRight?.keyEquivalent == "]")
    #expect(moveRight?.keyEquivalentModifierMask == [.command, .shift])

    let automaticLanguage = menuItem("Auto", in: menu)
    let plainText = menuItem("Plain Text", in: menu)
    let toggleComment = menuItem("Toggle Line Comment", in: menu)
    let languagePalette = menuItem("Language Command Palette…", in: menu)
    #expect(automaticLanguage?.action == #selector(DuckpadWindowController.performAutomaticLanguage(_:)))
    #expect(plainText?.action == #selector(DuckpadWindowController.performChooseLanguage(_:)))
    #expect(plainText?.representedObject as? String == LanguageID.plainText.rawValue)
    #expect(toggleComment?.action == #selector(DuckpadWindowController.performToggleLineComment(_:)))
    #expect(toggleComment?.keyEquivalent == "/")
    #expect(toggleComment?.keyEquivalentModifierMask == [.command])
    #expect(languagePalette?.action == #selector(DuckpadWindowController.performShowLanguageChooser(_:)))
    #expect(languagePalette?.keyEquivalentModifierMask == [.command, .shift])

    let wordWrap = menuItem("Word Wrap", in: menu)
    let wrapSymbols = menuItem("Show Wrap Symbols", in: menu)
    #expect(wordWrap?.action == #selector(DuckpadWindowController.performToggleWordWrap(_:)))
    #expect(wrapSymbols?.action == #selector(DuckpadWindowController.performToggleWrapMarker(_:)))
    if let wordWrap {
        #expect(controller.validateMenuItem(wordWrap))
        #expect(wordWrap.state == .on)
        controller.performToggleWordWrap(wordWrap)
        #expect(controller.validateMenuItem(wordWrap))
        #expect(wordWrap.state == .off)
        #expect(controller.editor.textView.isHorizontallyResizable)
        #expect(controller.editor.scrollView.hasHorizontalScroller)
    }
    if let wrapSymbols {
        #expect(!controller.validateMenuItem(wrapSymbols))
        #expect(wrapSymbols.state == .off)
    }
}

@Test @MainActor func layoutCacheIsSinglePassOOneLookupAndInvalidatesForEngineChanges() {
    let tabs = makeTabs(count: 500, activeIndex: 250)
    let (window, _, strip) = hostStrip(width: 560, height: 360, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let initialGeneration = strip.flowLayout.layoutGeneration
    for index in 0..<500 {
        #expect(strip.flowLayout.row(forItemAt: index) != nil)
        _ = strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
    }
    #expect(strip.flowLayout.layoutGeneration == initialGeneration)

    let oldHeight = strip.flowLayout.layoutAttributesForItem(
        at: IndexPath(item: 0, section: 0)
    )?.frame.height
    var changedEngine = strip.flowLayout.engine
    changedEngine.rowHeight += 7
    changedEngine.horizontalSpacing += 2
    strip.flowLayout.engine = changedEngine
    strip.hostedCollectionView.layoutSubtreeIfNeeded()
    #expect(strip.flowLayout.layoutGeneration == initialGeneration + 1)
    #expect(strip.flowLayout.layoutAttributesForItem(
        at: IndexPath(item: 0, section: 0)
    )?.frame.height == oldHeight.map { $0 + 7 })
}

@Test @MainActor func collectionExposesDragWriterAndRoutesMiddleClickAndDrop() {
    let tabs = makeTabs(count: 12, activeIndex: 0)
    let (window, _, strip) = hostStrip(width: 300, height: 320, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    var closed: TabID?
    var move: (TabID, Int)?
    strip.onClose = { closed = $0 }
    strip.onMove = { move = ($0, $1) }

    let writer = strip.collectionView(
        strip.hostedCollectionView,
        pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)
    )
    #expect(writer != nil)
    strip.performMiddleClick(tabID: tabs[4].id)
    strip.performDrop(tabID: tabs[1].id, to: 9)
    #expect(closed == tabs[4].id)
    #expect(move?.0 == tabs[1].id)
    #expect(move?.1 == 9)
}

@Test @MainActor func headlessCollectionPasteboardAcceptsCrossRowDropAtEnd() {
    let tabs = makeTabs(count: 12, activeIndex: 0)
    let (window, _, strip) = hostStrip(width: 300, height: 320, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let pasteboard = NSPasteboard(name: .init("duckpad.tab.drag.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    guard let writer = strip.collectionView(
        strip.hostedCollectionView,
        pasteboardWriterForItemAt: IndexPath(item: 1, section: 0)
    ) else {
        Issue.record("collection did not expose a drag writer")
        return
    }
    #expect(pasteboard.writeObjects([writer]))
    var move: (TabID, Int)?
    strip.onMove = { move = ($0, $1) }

    #expect(strip.acceptDrop(from: pasteboard, insertionIndex: tabs.count))
    #expect(move?.0 == tabs[1].id)
    #expect(move?.1 == tabs.count - 1)
}

@Test @MainActor func appKitHostedResizeCapsOverflowAndKeepsSelectedTabVisible() {
    let tabs = makeTabs(count: 500, activeIndex: 499)
    let (window, root, strip) = hostStrip(width: 700, height: 300, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let wideContentHeight = strip.contentHeight

    window.setContentSize(NSSize(width: 250, height: 300))
    root.frame.size = NSSize(width: 250, height: 300)
    root.layoutSubtreeIfNeeded()
    strip.layoutSubtreeIfNeeded()
    strip.hostedCollectionView.layoutSubtreeIfNeeded()
    strip.apply(tabs: tabs)

    #expect(strip.contentHeight > wideContentHeight)
    #expect(strip.viewportHeight <= root.bounds.height * strip.viewportPolicy.maximumWorkspaceFraction)
    #expect(strip.viewportHeight < strip.contentHeight)
    #expect(strip.hostedScrollView.documentView === strip.hostedCollectionView)
    #expect(strip.selectedTabIsVisible)
}

@Test @MainActor func hostedSelectionAndAccessibilityExposeStableStateAndActions() {
    let tabs = makeTabs(count: 50, activeIndex: 0, dirtyIndex: 0)
    let (window, _, strip) = hostStrip(width: 380, height: 320, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    var activated: TabID?
    var closed: TabID?
    strip.onActivate = { activated = $0 }
    strip.onClose = { closed = $0 }
    let firstPath = IndexPath(item: 0, section: 0)
    strip.collectionView(strip.hostedCollectionView, didSelectItemsAt: [firstPath])
    #expect(activated == tabs[0].id)

    guard let item = strip.hostedCollectionView.item(at: firstPath) else {
        Issue.record("expected visible AppKit collection item")
        return
    }
    let stableID = tabs[0].id.rawValue.uuidString.lowercased()
    #expect(item.view.accessibilityIdentifier() == "duckpad.tab.\(stableID)")
    #expect(item.view.accessibilityLabel() == "new 1 tab")
    let value = item.view.accessibilityValue() as? String
    #expect(value?.contains("selected") == true)
    #expect(value?.contains("modified") == true)
    #expect(value?.contains("pinned") == true)
    #expect(value?.contains("index 1") == true)
    #expect(value?.contains("row 1") == true)
    #expect(item.view.accessibilityPerformPress())
    #expect(activated == tabs[0].id)

    let closeButton = descendantButtons(of: item.view).first {
        $0.accessibilityIdentifier() == "duckpad.tab.close.\(stableID)"
    }
    #expect(closeButton?.accessibilityLabel() == "Close new 1")
    closeButton?.performClick(nil)
    #expect(closed == tabs[0].id)
}

@Test @MainActor func textViewAdapterOwnsLiveTextAndEmitsIncrementalRevisionCheckedEdit() async {
    let store = PresentationStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    _ = await workspace.start()
    let editor = TextViewEditorAdapter()
    let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
    binding.render(workspace.snapshot())
    let bufferID = workspace.snapshot().activeBuffer!.bufferID

    editor.textView.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0),
        with: "duck"
    )
    await Task.yield()
    #expect(editor.snapshot(for: bufferID) == EditorTextSnapshot(
        bufferID: bufferID,
        revision: 1,
        text: "duck"
    ))
    #expect(workspace.snapshot().activeBuffer?.revision == 1)
    #expect(workspace.snapshot().tabs[0].isDirty)
    #expect(await workspace.flushPersistence() == .saved)
}

@Test @MainActor func textViewAdapterRestoresSnapshotWhenEditRevisionIsRejected() {
    let editor = TextViewEditorAdapter()
    let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    editor.display(descriptor)
    editor.onEdit = { edit in .rejected(currentRevision: edit.expectedRevision) }
    editor.textView.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0),
        with: "rejected"
    )
    #expect(editor.textView.string == "")
    #expect(editor.snapshot(for: descriptor.bufferID)?.revision == 0)
}

@Test @MainActor func textViewFallbackKeepsWordWrapPerBufferAndAcrossRecovery() throws {
    let editor = TextViewEditorAdapter()
    let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    editor.display(first)
    editor.setWordWrapEnabled(false)
    #expect(editor.textView.isHorizontallyResizable)
    #expect(editor.scrollView.hasHorizontalScroller)

    editor.display(second)
    #expect(editor.isWordWrapEnabled)
    #expect(!editor.textView.isHorizontallyResizable)

    editor.display(first)
    #expect(!editor.isWordWrapEnabled)
    let recovery = try #require(editor.recoverySnapshot(for: first.bufferID))
    #expect(!recovery.viewState.wordWrapEnabled)

    let restored = TextViewEditorAdapter()
    restored.installRecovery(recovery)
    restored.display(first)
    #expect(!restored.isWordWrapEnabled)
    #expect(restored.scrollView.hasHorizontalScroller)
    #expect(!restored.supportsWrapMarker)
}

@Test @MainActor func textViewAdapterRetirementDropsTextAndUndoButPreservesInactiveOpenBuffer() {
    let editor = TextViewEditorAdapter()
    let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
    editor.display(first)
    editor.textView.insertText("secret", replacementRange: NSRange(location: 0, length: 0))
    editor.display(second)
    editor.textView.insertText("open", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.snapshot(for: first.bufferID)?.text == "secret")
    #expect(editor.snapshot(for: second.bufferID)?.text == "open")

    editor.retire(bufferID: first.bufferID)
    #expect(editor.snapshot(for: first.bufferID) == nil)
    #expect(editor.snapshot(for: second.bufferID)?.text == "open")
    editor.retire(bufferID: second.bufferID)
    #expect(editor.snapshot(for: second.bufferID) == nil)
    #expect(editor.textView.string == "")
    #expect(editor.textView.undoManager?.canUndo != true)
}

@Test @MainActor func perBufferUndoSurvivesEditingAndRetiringAnotherBuffer() {
    let editor = TextViewEditorAdapter()
    let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
    editor.display(first)
    editor.textView.insertText("A", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.textView.undoManager?.canUndo == true)
    editor.display(second)
    editor.textView.insertText("B", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.textView.undoManager?.canUndo == true)

    editor.retire(bufferID: second.bufferID)
    editor.display(EditorBufferDescriptor(bufferID: first.bufferID, revision: 1))
    #expect(editor.textView.string == "A")
    #expect(editor.textView.undoManager?.canUndo == true)
    editor.textView.undoManager?.undo()
    #expect(editor.textView.string == "")
    #expect(editor.snapshot(for: first.bufferID)?.text == "")
}

@Test @MainActor func fiveHundredTabTypingReloadsOnlyChangedItemWithinBudget() {
    let tabs = makeTabs(count: 500, activeIndex: 250)
    let (window, _, strip) = hostStrip(width: 700, height: 400, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    var changedTabs = tabs
    let original = changedTabs[250]
    changedTabs[250] = TabSnapshot(
        id: original.id,
        title: original.title,
        isActive: true,
        isDirty: true,
        isPinned: original.isPinned,
        buffer: EditorBufferDescriptor(bufferID: original.buffer.bufferID, revision: 1)
    )
    let before = strip.updateMetrics
    let snapshot = WorkspaceSnapshot(
        sessionID: SessionID(),
        tabs: changedTabs,
        activeBuffer: changedTabs[250].buffer,
        persistence: .pending,
        startup: .ready
    )
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        strip.apply(change: WorkspaceChange(snapshot: snapshot, kind: .tabUpdated(index: 250)))
    }
    #expect(strip.updateMetrics.fullReloads == before.fullReloads)
    #expect(strip.updateMetrics.itemReloads == before.itemReloads + 1)
    #expect(elapsed < .milliseconds(250))
}

@Test @MainActor func controllerSurfacesEveryPersistenceFailureOnceWithRetry() async {
    let loadStore = PresentationStore()
    await loadStore.setFailure(.unavailable("load offline"), forLoad: true)
    let loadWorkspace = ScratchWorkspaceUseCase(store: loadStore)
    let presenter = ErrorPresenterSpy()
    var loadController: DuckpadWindowController? = DuckpadWindowController(
        workspace: loadWorkspace,
        errorPresenter: presenter,
        automaticallyStarts: false
    )
    loadController?.start()
    await loadController?.waitForStartup()
    #expect(presenter.failures.count == 1)
    #expect(presenter.failures[0].operation == .load)
    loadController?.window?.contentViewController = nil
    loadController?.close()
    loadController = nil

    let store = PresentationStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    let operationPresenter = ErrorPresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        errorPresenter: operationPresenter,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()
    _ = await workspace.addScratch()
    let firstTab = workspace.snapshot().tabs[0].id

    await store.setFailure(.unavailable("save offline"))
    _ = await workspace.addScratch()
    _ = await workspace.activate(tabID: firstTab)
    let active = workspace.snapshot().activeBuffer!
    _ = workspace.acceptEditorEdit(EditorIncrementalEdit(
        bufferID: active.bufferID,
        expectedRevision: active.revision,
        range: TextEditRange(location: 0, length: 0),
        replacement: "dirty"
    ))
    await workspace.waitForPendingPersistence()
    let dirtyTab = workspace.snapshot().tabs.first(where: \.isActive)!.id
    _ = await workspace.close(tabID: dirtyTab, decision: .discard)

    #expect(operationPresenter.failures.count == 4)
    #expect(operationPresenter.failures.allSatisfy { $0.operation == .save })
    #expect(operationPresenter.retries.count == 4)
    await store.setFailure(nil)
    operationPresenter.retries.last?()
    for _ in 0..<100 where workspace.snapshot().tabs.count != 1 { await Task.yield() }
    #expect(workspace.snapshot().tabs.count == 1)
    #expect(operationPresenter.failures.count == 4)
    controller.window?.contentViewController = nil
    controller.close()
}

@Test @MainActor func routedClosePersistenceFailureIsPresentedOnceWithActionableRetry() async throws {
    var restored = ScratchSession()
    let dirtyTab = restored.addUntitled()
    _ = try restored.recordEdit(in: dirtyTab, expectedRevision: 0)
    let store = PresentationStore(session: restored)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let presenter = ErrorPresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        errorPresenter: presenter,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    await store.setFailure(.unavailable("close persistence offline"))

    controller.performClose(dirtyTab, decision: .discard)
    for _ in 0..<1_000 where presenter.failures.isEmpty { await Task.yield() }
    #expect(presenter.failures.count == 1)
    #expect(presenter.retries.count == 1)
    #expect(workspace.snapshot().tabs.first?.id == dirtyTab)
    await store.setFailure(nil)
    presenter.retries[0]()
    for _ in 0..<1_000 where workspace.snapshot().tabs.first?.id == dirtyTab { await Task.yield() }
    #expect(workspace.snapshot().tabs.first?.id != dirtyTab)
    #expect(presenter.failures.count == 1)
}

@Test @MainActor func realControllerDisablesEditorUntilDelayedRestoreCompletes() async {
    var restored = ScratchSession()
    restored.addUntitled()
    let store = DelayedPresentationStore(session: restored)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    controller.start()
    await store.waitUntilEntered()
    #expect(workspace.snapshot().startup == .restoring)
    #expect(!controller.editor.textView.isEditable)
    #expect(!controller.editor.textView.isSelectable)
    let wordWrap = NSMenuItem(
        title: "Word Wrap",
        action: #selector(DuckpadWindowController.performToggleWordWrap(_:)),
        keyEquivalent: ""
    )
    #expect(!controller.validateMenuItem(wordWrap))
    controller.performToggleWordWrap(wordWrap)
    #expect(controller.editor.isWordWrapEnabled)
    controller.editor.textView.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
    #expect(controller.editor.textView.string == "")

    await store.release()
    await controller.waitForStartup()
    #expect(workspace.snapshot().startup == .ready)
    #expect(controller.editor.textView.isEditable)
    #expect(controller.editor.textView.isSelectable)
    #expect(controller.validateMenuItem(wordWrap))
    #expect(wordWrap.state == .on)
    #expect(controller.editor.textView.string == "")
    controller.close()
}

@Test @MainActor func realControllerTypingWithFiveHundredTabsPerformsOneItemReload() async {
    var session = ScratchSession()
    for _ in 0..<500 { session.addUntitled() }
    let store = PresentationStore(session: session)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    controller.start()
    await controller.waitForStartup()
    let before = controller.tabStrip.updateMetrics
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        controller.editor.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: "x"
        )
    }
    #expect(workspace.snapshot().tabs.count == 500)
    #expect(workspace.snapshot().tabs.last?.isDirty == true)
    #expect(controller.tabStrip.updateMetrics.fullReloads == before.fullReloads)
    #expect(controller.tabStrip.updateMetrics.itemReloads == before.itemReloads + 1)
    #expect(elapsed < .milliseconds(250))
    await workspace.waitForPendingPersistence()
    #expect(controller.tabStrip.updateMetrics.fullReloads == before.fullReloads)
    #expect(controller.tabStrip.updateMetrics.itemReloads == before.itemReloads + 1)
    controller.close()
}

@Test @MainActor func controllerWindowAndHostedViewsDeallocateWithoutGlobalLeak() {
    let store = PresentationStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    let (controllerBox, windowBox) = makeAndCloseController(workspace: workspace)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    #expect(controllerBox.value == nil)
    #expect(windowBox.value == nil)
}
}
