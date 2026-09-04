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
    private var blockNextCommit = false
    private var blockedCommitEntered = false
    private var releaseBlockedCommit = false
    init(session: ScratchSession? = nil) { self.session = session }
    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        if failLoad, let failure { throw failure }
        return session.map { StoredSession(session: $0, generation: generation) }
    }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        commitAttempts += 1
        if blockNextCommit {
            blockNextCommit = false
            blockedCommitEntered = true
            while !releaseBlockedCommit { await Task.yield() }
        }
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
    func armBlockingCommit() {
        blockNextCommit = true
        blockedCommitEntered = false
        releaseBlockedCommit = false
    }
    func waitUntilCommitEntered() async {
        while !blockedCommitEntered { await Task.yield() }
    }
    func releaseCommit() { releaseBlockedCommit = true }
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

@MainActor
private final class FixedDirtyDecisionPresenter: DirtyDocumentDecisionPresenting {
    let result: CloseDecision
    init(_ result: CloseDecision) { self.result = result }
    func decision(
        for tab: TabSnapshot,
        saveAvailable: Bool,
        attachedTo window: NSWindow?
    ) async -> CloseDecision { result }
}

@MainActor
private final class NavigationPresenterSpy: EditorNavigationPresenting {
    private(set) var linePosition: EditorNavigationPosition?
    private(set) var offsetPosition: EditorNavigationPosition?
    var lineCompletion: ((Int, Int) -> Void)?
    var offsetCompletion: ((Int) -> Void)?

    func presentLineAndColumn(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int, Int) -> Void
    ) {
        linePosition = current
        lineCompletion = completion
    }

    func presentUTF8Offset(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int) -> Void
    ) {
        offsetPosition = current
        offsetCompletion = completion
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

@MainActor
private final class ApplicationMenuTargetSpy: NSObject, DuckpadApplicationCommandTarget {
    private(set) var settingsRequests = 0
    private(set) var openedRecentURLs: [URL] = []
    private(set) var clearRecentRequests = 0

    @objc func performShowSettings(_ sender: Any?) {
        settingsRequests += 1
    }

    @objc func performOpenRecentDocument(_ sender: Any?) {
        if let url = (sender as? NSMenuItem)?.representedObject as? URL {
            openedRecentURLs.append(url)
        }
    }

    @objc func performClearRecentDocuments(_ sender: Any?) {
        clearRecentRequests += 1
    }
}

@MainActor
private final class HostedLanguageEditorFake: LanguageEditorPort, DocumentIntelligenceEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var supportedLexers: Set<String> = []
    var prefix = Data()
    var configurations: [EditorLanguageConfiguration] = []
    private(set) var themes: [EditorThemePalette] = []
    private(set) var mutationCount = 0
    var canToggleBlockComment: Bool { false }
    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private(set) var presentedCompletionItems: [String] = []
    private(set) var revealedRange: SearchUTF8Range?
    private(set) var completionCancellationCount = 0

    var activeLanguageID: LanguageID { configurations.last?.languageID ?? .plainText }
    var isLanguageStylingFallback: Bool { false }
    var activeDocumentByteLength: Int {
        guard let activeBuffer else { return 0 }
        return snapshots[activeBuffer.bufferID]?.text.utf8.count ?? 0
    }
    var activeDocumentIntelligenceBuffer: EditorBufferDescriptor? { activeBuffer }
    var activeDocumentIntelligenceByteLength: Int { activeDocumentByteLength }

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
    func applyTheme(_ palette: EditorThemePalette) { themes.append(palette) }
    func toggleLineComment(prefix: String) -> EditorEditOutcome {
        mutationCount += 1
        return .rejected(currentRevision: activeBuffer?.revision ?? 0)
    }
    func toggleBlockComment() -> EditorEditOutcome {
        .rejected(currentRevision: activeBuffer?.revision ?? 0)
    }
    func captureDocumentIntelligence(maximumBytes: Int) -> DocumentIntelligenceCapture? {
        guard let activeBuffer, let snapshot = snapshots[activeBuffer.bufferID] else { return nil }
        let bytes = Data(snapshot.text.utf8)
        guard bytes.count <= maximumBytes else { return nil }
        return DocumentIntelligenceCapture(
            buffer: activeBuffer,
            utf8: bytes,
            caretUTF8: bytes.count,
            languageID: activeLanguageID,
            contextID: .init()
        )
    }
    func presentCompletionItems(
        _ items: [String],
        replacingPrefixByteCount: Int,
        expectedBuffer: EditorBufferDescriptor,
        expectedCaretUTF8: Int,
        expectedContextID: DocumentIntelligenceContextID
    ) -> Bool {
        guard expectedBuffer == activeBuffer,
              expectedCaretUTF8 == activeDocumentByteLength else { return false }
        presentedCompletionItems = items
        return true
    }
    func cancelCompletion() {
        completionCancellationCount += 1
        presentedCompletionItems = []
    }
    func selectAndReveal(_ range: SearchUTF8Range) { revealedRange = range }
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
private func descendantTextFields(of view: NSView) -> [NSTextField] {
    let direct = view.subviews.compactMap { $0 as? NSTextField }
    return direct + view.subviews.flatMap(descendantTextFields)
}

@MainActor
private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
        if item.title == title { return item }
        if let submenu = item.submenu, let found = menuItem(title, in: submenu) { return found }
    }
    return nil
}

@MainActor
private func flattenedMenuItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items + menu.items.compactMap(\.submenu).flatMap(flattenedMenuItems)
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

@Test func explicitWidthBoundsDoNotForceTitlesDownToTheViewportWidth() {
    let engine = TabFlowLayoutEngine(minimumItemWidth: 90, maximumItemWidth: 180)
    let result = engine.layout(itemWidths: [20, 500], containerWidth: 95)
    #expect(result.frames.map(\.width) == [90, 180])
    #expect(result.contentWidth >= 186)
    #expect(result.rowCount == 2)
}

@Test func defaultLayoutPreservesTheFullProposedTabWidth() {
    let engine = TabFlowLayoutEngine()
    let result = engine.layout(itemWidths: [640], containerWidth: 240)

    #expect(result.frames.first?.width == 640)
    #expect(result.contentWidth >= 646)
    #expect(result.rowCount == 1)
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
@Test @MainActor func documentSwitcherSearchMatchesTitlePathAndDiacriticsDeterministically() {
    let tabs = [
        TabSnapshot(
            id: TabID(), title: "Résumé.md", isActive: false, isDirty: false, isPinned: false,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0),
            fullPath: "/Users/duck/Notes/Résumé.md"
        ),
        TabSnapshot(
            id: TabID(), title: "server.swift", isActive: true, isDirty: true, isPinned: false,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 1),
            fullPath: "/Users/duck/Sources/API/server.swift"
        ),
        TabSnapshot(
            id: TabID(), title: "scratch SQL", isActive: false, isDirty: false, isPinned: true,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        ),
    ]

    #expect(DocumentSwitcherSearch.matchingIndices(in: tabs, query: "resume") == [0])
    #expect(DocumentSwitcherSearch.matchingIndices(in: tabs, query: "api swift") == [1])
    #expect(DocumentSwitcherSearch.matchingIndices(in: tabs, query: "SCRATCH sql") == [2])
    #expect(DocumentSwitcherSearch.matchingIndices(in: tabs, query: "missing").isEmpty)
    #expect(DocumentSwitcherSearch.matchingIndices(in: tabs, query: "   ") == [0, 1, 2])

    let exactTitle = TabSnapshot(
        id: TabID(), title: "server swift", isActive: false, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0),
        fullPath: "/Later/server-swift.txt"
    )
    let pathMixed = TabSnapshot(
        id: TabID(), title: "server", isActive: false, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0),
        fullPath: "/Earlier/swift/server.txt"
    )
    #expect(
        DocumentSwitcherSearch.matchingIndices(in: [pathMixed, exactTitle], query: "server swift")
            == [1, 0]
    )

    let manyTerms = "a b c d e f g h i j"
    let phraseContained = TabSnapshot(
        id: TabID(), title: String(repeating: "x", count: 1_200) + manyTerms,
        isActive: false, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
    let allTermsOnly = TabSnapshot(
        id: TabID(), title: "abcdefghij", isActive: false, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
    #expect(
        DocumentSwitcherSearch.matchingIndices(
            in: [allTermsOnly, phraseContained], query: manyTerms
        ) == [1, 0]
    )
}

@Test @MainActor func documentSwitcherPanelRoutesFilteredSelectionByStableTabIdentity() {
    _ = NSApplication.shared
    let tabs = makeTabs(count: 4, activeIndex: 1, dirtyIndex: 3)
    let panel = DocumentSwitcherPanel()
    var activated: TabID?
    panel.onActivate = { activated = $0 }
    panel.apply(tabs: tabs)
    #expect(panel.selectedTabID == tabs[1].id)

    #expect(panel.control(
        NSSearchField(), textView: NSTextView(),
        doCommandBy: #selector(NSResponder.moveDown(_:))
    ))
    #expect(panel.selectedTabID == tabs[2].id)

    panel.setQuery("new 4")
    #expect(panel.filteredTabs.map(\.id) == [tabs[3].id])
    panel.activateSelectedResult()
    #expect(activated == tabs[3].id)

    activated = nil
    panel.setQuery("does-not-exist")
    panel.activateSelectedResult()
    #expect(activated == nil)
}

@Test @MainActor func documentSwitcherSearchHandlesFiveThousandTabsWithinInteractionBudget() {
    let tabs = makeTabs(count: 5_000, activeIndex: 2_500)
    let clock = ContinuousClock()
    var result: [Int] = []
    let elapsed = clock.measure {
        result = DocumentSwitcherSearch.matchingIndices(in: tabs, query: "new 4999")
    }
    #expect(result == [4_998])
    #expect(elapsed < .milliseconds(250))
}

@Test @MainActor func documentSwitcherPopoverOpensFromChromeAndClosesWhenInteractionsLock() {
    let tabs = makeTabs(count: 8, activeIndex: 3)
    let (window, _, strip) = hostStrip(width: 560, height: 360, tabs: tabs)
    defer {
        strip.documentSwitcher.documentPanel.dismiss()
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    window.makeKeyAndOrderFront(nil)
    strip.setInteractionsEnabled(true)

    strip.documentSwitcher.showDocumentSwitcher()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(strip.documentSwitcher.documentPanel.isPresented)
    #expect(strip.documentSwitcher.documentPanel.selectedTabID == tabs[3].id)

    let expanded = tabs + [
        TabSnapshot(
            id: TabID(), title: "late document", isActive: false, isDirty: false, isPinned: false,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        ),
    ]
    strip.apply(tabs: expanded)
    #expect(strip.documentSwitcher.documentPanel.tabs.count == expanded.count)

    strip.setInteractionsEnabled(false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    #expect(!strip.documentSwitcher.documentPanel.isPresented)
}

@Test @MainActor func documentSwitcherPopoverClosesWithItsHostWindow() {
    let tabs = makeTabs(count: 3, activeIndex: 0)
    let (window, _, strip) = hostStrip(width: 500, height: 300, tabs: tabs)
    window.makeKeyAndOrderFront(nil)
    strip.setInteractionsEnabled(true)
    strip.documentSwitcher.showDocumentSwitcher()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(strip.documentSwitcher.documentPanel.isPresented)

    window.close()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    #expect(!strip.documentSwitcher.documentPanel.isPresented)
    strip.tearDownHostedViews()
    window.contentView = nil
}

@Test @MainActor func documentSwitcherChromeMirrorsOpenTabsAndUpdatesIncrementally() {
    _ = NSApplication.shared
    let tabs = makeTabs(count: 3, activeIndex: 1, dirtyIndex: 2)
    let (window, _, strip) = hostStrip(width: 420, height: 280, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }

    #expect(strip.documentSwitcher.tabs.count == 3)
    #expect(strip.documentSwitcher.title == "Documents (3)")
    #expect(strip.documentSwitcher.tabs.map(\.isActive) == [false, true, false])
    #expect(strip.documentSwitcher.tabs[2].isDirty)

    let before = strip.documentSwitcher.updateMetrics
    var updated = tabs
    updated[2] = TabSnapshot(
        id: tabs[2].id,
        title: tabs[2].title,
        isActive: false,
        isDirty: false,
        isPinned: tabs[2].isPinned,
        buffer: EditorBufferDescriptor(bufferID: tabs[2].buffer.bufferID, revision: 2)
    )
    strip.apply(change: WorkspaceChange(
        snapshot: WorkspaceSnapshot(
            sessionID: SessionID(),
            tabs: updated,
            activeBuffer: updated[1].buffer,
            persistence: .saved,
            startup: .ready
        ),
        kind: .bufferEdited(index: 2)
    ))
    #expect(strip.documentSwitcher.updateMetrics.fullRebuilds == before.fullRebuilds)
    #expect(strip.documentSwitcher.updateMetrics.itemUpdates == before.itemUpdates + 1)
    #expect(
        strip.documentSwitcher.updateMetrics.incrementalItemInspections
            == before.incrementalItemInspections + 1
    )
    #expect(!strip.documentSwitcher.tabs[2].isDirty)

    let activeBefore = strip.documentSwitcher.updateMetrics
    updated[1] = TabSnapshot(
        id: updated[1].id, title: updated[1].title, isActive: false,
        isDirty: updated[1].isDirty, isPinned: updated[1].isPinned,
        buffer: updated[1].buffer
    )
    updated[0] = TabSnapshot(
        id: updated[0].id, title: updated[0].title, isActive: true,
        isDirty: updated[0].isDirty, isPinned: updated[0].isPinned,
        buffer: updated[0].buffer
    )
    strip.apply(change: WorkspaceChange(
        snapshot: WorkspaceSnapshot(
            sessionID: SessionID(), tabs: updated,
            activeBuffer: updated[0].buffer, persistence: .saved, startup: .ready
        ),
        kind: .activeTabChanged(previousIndex: 1, currentIndex: 0)
    ))
    #expect(strip.documentSwitcher.tabs.map(\.isActive) == [true, false, false])
    #expect(strip.documentSwitcher.updateMetrics.itemUpdates == activeBefore.itemUpdates + 2)
    #expect(
        strip.documentSwitcher.updateMetrics.incrementalItemInspections
            == activeBefore.incrementalItemInspections + 2
    )
}

@Test @MainActor func documentSwitcherIncrementalWorkStaysConstantAtScale() {
    _ = NSApplication.shared
    for count in [500, 5_000] {
        let button = DocumentSwitcherButton(frame: .zero)
        var tabs = makeTabs(count: count, activeIndex: count / 2)
        button.apply(tabs: tabs)
        let index = count / 3
        let original = tabs[index]
        tabs[index] = TabSnapshot(
            id: original.id, title: original.title, isActive: original.isActive,
            isDirty: true, isPinned: original.isPinned,
            buffer: EditorBufferDescriptor(
                bufferID: original.buffer.bufferID,
                revision: original.buffer.revision + 1
            )
        )
        let before = button.updateMetrics
        button.apply(change: WorkspaceChange(
            snapshot: WorkspaceSnapshot(
                sessionID: SessionID(), tabs: tabs,
                activeBuffer: tabs[count / 2].buffer,
                persistence: .pending, startup: .ready
            ),
            kind: .bufferEdited(index: index)
        ))
        #expect(button.updateMetrics.fullRebuilds == before.fullRebuilds)
        #expect(button.updateMetrics.itemUpdates == before.itemUpdates + 1)
        #expect(
            button.updateMetrics.incrementalItemInspections
                == before.incrementalItemInspections + 1
        )
    }
}

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
    let languageMenu = controller.makeLanguageStatusMenu()
    #expect(menuItem("Automatic Detection", in: languageMenu)?.state == .on)
    #expect(menuItem("Python", in: languageMenu)?.state == .off)
    #expect(try workspace.recoverySession().languageOverride(for: tabID) == .automatic)
    #expect(workspace.snapshot().activeBuffer?.revision == beforeBuffer?.revision)
    #expect(editor.snapshot(for: beforeText.bufferID) == beforeText)
    #expect(editor.mutationCount == 0)
}

@Test @MainActor func effectiveAppearanceChangesRefreshTheEditorPalette() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let editor = HostedLanguageEditorFake()
    editor.supportedLexers = ["null"]
    let registry = try LanguageRegistry(definitions: [
        LanguageDefinition(
            id: .plainText,
            displayName: "Plain Text",
            group: "Text",
            lexerName: "null",
            supportTier: .plain
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

    controller.window?.appearance = NSAppearance(named: .darkAqua)
    await Task.yield()
    let darkPalette: EditorThemePalette = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ? .highContrastDark
        : .dark
    #expect(editor.themes.last == darkPalette)

    controller.window?.appearance = NSAppearance(named: .aqua)
    await Task.yield()
    let lightPalette: EditorThemePalette = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ? .highContrastLight
        : .light
    #expect(editor.themes.last == lightPalette)

    let beforeAccessibilityNotification = editor.themes.count
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil
    )
    await Task.yield()
    #expect(editor.themes.count == beforeAccessibilityNotification + 1)
}

@Test @MainActor func applicationSettingsUsesAnAppLifetimeTargetAfterDocumentClose() throws {
    _ = NSApplication.shared
    let applicationTarget = ApplicationMenuTargetSpy()
    let controller = DuckpadWindowController(
        workspace: ScratchWorkspaceUseCase(store: PresentationStore()),
        automaticallyStarts: false
    )
    let menu = DuckpadMainMenuFactory.make(
        target: controller,
        applicationTarget: applicationTarget
    )
    controller.close()
    let settings = try #require(menuItem("Settings…", in: menu))
    #expect(settings.target === applicationTarget)

    #expect(settings.target === applicationTarget)
    #expect(NSApplication.shared.sendAction(
        try #require(settings.action),
        to: settings.target,
        from: settings
    ))
    #expect(applicationTarget.settingsRequests == 1)
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

    let settings = menuItem("Settings…", in: menu)
    #expect(settings?.action == #selector(DuckpadWindowController.performShowSettings(_:)))
    #expect(settings?.keyEquivalent == ",")
    #expect(settings?.keyEquivalentModifierMask == [.command])
    var settingsRequests = 0
    controller.onSettingsRequested = { settingsRequests += 1 }
    controller.performShowSettings()
    #expect(settingsRequests == 1)
    if let settings { #expect(controller.validateMenuItem(settings)) }

    let newScratch = menuItem("New Scratch", in: menu)
    #expect(newScratch?.action == #selector(DuckpadWindowController.performNewScratch(_:)))
    #expect(newScratch?.keyEquivalent == "n")
    #expect(newScratch?.keyEquivalentModifierMask == [.command])

    let newWindow = menuItem("New Window", in: menu)
    #expect(newWindow?.action == #selector(DuckpadWindowController.performNewWindow(_:)))
    #expect(newWindow?.keyEquivalent == "n")
    #expect(newWindow?.keyEquivalentModifierMask == [.command, .shift])
    var newWindowRequests = 0
    controller.onNewWindowRequested = { newWindowRequests += 1 }
    controller.performNewWindow()
    #expect(newWindowRequests == 1)

    let saveCopy = menuItem("Save a Copy As…", in: menu)
    let saveAll = menuItem("Save All", in: menu)
    #expect(saveCopy?.action == #selector(DuckpadWindowController.performSaveCopyAs(_:)))
    #expect(saveCopy?.keyEquivalent == "s")
    #expect(saveCopy?.keyEquivalentModifierMask == [.command, .option, .shift])
    #expect(saveAll?.action == #selector(DuckpadWindowController.performSaveAll(_:)))
    #expect(saveAll?.keyEquivalent == "s")
    #expect(saveAll?.keyEquivalentModifierMask == [.command, .option])
    if let saveAll { #expect(!controller.validateMenuItem(saveAll)) }

    #expect(menuItem("Minimize", in: menu)?.keyEquivalentModifierMask == [.command])
    #expect(menuItem("Enter Full Screen", in: menu)?.keyEquivalentModifierMask == [.command, .control])

    let undo = menuItem("Undo", in: menu)
    let redo = menuItem("Redo", in: menu)
    let cut = menuItem("Cut", in: menu)
    let copy = menuItem("Copy", in: menu)
    let paste = menuItem("Paste", in: menu)
    let delete = menuItem("Delete", in: menu)
    let selectAll = menuItem("Select All", in: menu)
    #expect(undo?.action == #selector(DuckpadWindowController.performUndo(_:)))
    #expect(undo?.keyEquivalent == "z")
    #expect(undo?.keyEquivalentModifierMask == [.command])
    #expect(redo?.action == #selector(DuckpadWindowController.performRedo(_:)))
    #expect(redo?.keyEquivalent == "z")
    #expect(redo?.keyEquivalentModifierMask == [.command, .shift])
    #expect(cut?.action == #selector(DuckpadWindowController.performCut(_:)))
    #expect(cut?.keyEquivalent == "x")
    #expect(copy?.action == #selector(DuckpadWindowController.performCopy(_:)))
    #expect(copy?.keyEquivalent == "c")
    #expect(paste?.action == #selector(DuckpadWindowController.performPaste(_:)))
    #expect(paste?.keyEquivalent == "v")
    #expect(delete?.action == #selector(DuckpadWindowController.performDelete(_:)))
    #expect(delete?.keyEquivalent.isEmpty == true)
    #expect(selectAll?.action == #selector(DuckpadWindowController.performSelectAll(_:)))
    #expect(selectAll?.keyEquivalent == "a")
    for item in [cut, copy, paste, selectAll].compactMap({ $0 }) {
        #expect(item.keyEquivalentModifierMask == [.command])
    }
    let completeWord = menuItem("Complete Current Document Word", in: menu)
    #expect(completeWord?.action == #selector(DuckpadWindowController.performCompleteCurrentDocumentWord(_:)))
    #expect(completeWord?.keyEquivalent == " ")
    #expect(completeWord?.keyEquivalentModifierMask == [.control])
    if let completeWord { #expect(!controller.validateMenuItem(completeWord)) }

    let utf8 = menuItem("UTF-8 without BOM", in: menu)
    let utf8BOM = menuItem("UTF-8 with BOM", in: menu)
    let utf16LE = menuItem("UTF-16 LE with BOM", in: menu)
    let utf16LENoBOM = menuItem("UTF-16 LE without BOM", in: menu)
    let utf16BE = menuItem("UTF-16 BE with BOM", in: menu)
    let utf16BENoBOM = menuItem("UTF-16 BE without BOM", in: menu)
    let lf = menuItem("Unix (LF)", in: menu)
    let crlf = menuItem("Windows (CRLF)", in: menu)
    let cr = menuItem("Classic Mac (CR)", in: menu)
    let openUTF16LE = menuItem("Open as UTF-16 LE…", in: menu)
    #expect(utf8?.action == #selector(DuckpadWindowController.performConvertToUTF8(_:)))
    #expect(utf8BOM?.action == #selector(DuckpadWindowController.performConvertToUTF8BOM(_:)))
    #expect(utf16LE?.action == #selector(DuckpadWindowController.performConvertToUTF16LittleEndian(_:)))
    #expect(utf16LENoBOM?.action == #selector(DuckpadWindowController.performConvertToUTF16LittleEndianWithoutBOM(_:)))
    #expect(utf16BE?.action == #selector(DuckpadWindowController.performConvertToUTF16BigEndian(_:)))
    #expect(utf16BENoBOM?.action == #selector(DuckpadWindowController.performConvertToUTF16BigEndianWithoutBOM(_:)))
    #expect(lf?.action == #selector(DuckpadWindowController.performConvertToLF(_:)))
    #expect(crlf?.action == #selector(DuckpadWindowController.performConvertToCRLF(_:)))
    #expect(cr?.action == #selector(DuckpadWindowController.performConvertToCR(_:)))
    #expect(openUTF16LE?.action == #selector(DuckpadWindowController.performOpenAsUTF16LittleEndian(_:)))
    for item in [utf8, utf8BOM, utf16LE, utf16LENoBOM, utf16BE, utf16BENoBOM, lf, crlf, cr, openUTF16LE].compactMap({ $0 }) {
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
        #expect(!controller.validateMenuItem(item))
    }
    #expect(utf8?.state == .on)

    let duplicateLine = menuItem("Duplicate Line", in: menu)
    let moveLineUp = menuItem("Move Line Up", in: menu)
    let moveLineDown = menuItem("Move Line Down", in: menu)
    let deleteLine = menuItem("Delete Line", in: menu)
    let joinLines = menuItem("Join Lines", in: menu)
    #expect(duplicateLine?.keyEquivalent == "d")
    #expect(duplicateLine?.keyEquivalentModifierMask == [.command])
    #expect(moveLineUp?.keyEquivalent == String(UnicodeScalar(NSUpArrowFunctionKey)!))
    #expect(moveLineUp?.keyEquivalentModifierMask == [.option])
    #expect(moveLineDown?.keyEquivalent == String(UnicodeScalar(NSDownArrowFunctionKey)!))
    #expect(moveLineDown?.keyEquivalentModifierMask == [.option])
    #expect(deleteLine?.keyEquivalent == "k")
    #expect(deleteLine?.keyEquivalentModifierMask == [.command, .shift])
    #expect(joinLines?.keyEquivalent == "j")
    #expect(joinLines?.keyEquivalentModifierMask == [.control])
    for title in ["Indent Line(s)", "Unindent Line(s)", "Make Uppercase", "Make Lowercase", "Trim Trailing Whitespace"] {
        #expect(menuItem(title, in: menu)?.keyEquivalent.isEmpty == true)
    }

    let shortcuts = flattenedMenuItems(in: menu).compactMap { item -> String? in
        guard !item.keyEquivalent.isEmpty else { return nil }
        return "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent.lowercased())"
    }
    #expect(Set(shortcuts).count == shortcuts.count)

    let findInFolder = menuItem("Find in Folder…", in: menu)
    #expect(findInFolder?.action == #selector(DuckpadWindowController.performFindInFolder(_:)))
    #expect(findInFolder?.keyEquivalent == "f")
    #expect(findInFolder?.keyEquivalentModifierMask == [.command, .shift])
    let goToLine = menuItem("Go to Line / Column…", in: menu)
    let goToOffset = menuItem("Go to UTF-8 Offset…", in: menu)
    #expect(goToLine?.action == #selector(DuckpadWindowController.performGoToLine(_:)))
    #expect(goToLine?.keyEquivalent == "g")
    #expect(goToLine?.keyEquivalentModifierMask == [.control])
    #expect(goToOffset?.action == #selector(DuckpadWindowController.performGoToOffset(_:)))
    #expect(goToOffset?.keyEquivalent.isEmpty == true)
    if let goToLine, let goToOffset {
        #expect(controller.validateMenuItem(goToLine))
        #expect(controller.validateMenuItem(goToOffset))
    }

    let f2 = String(UnicodeScalar(NSF2FunctionKey)!)
    let toggleBookmark = menuItem("Toggle Bookmark", in: menu)
    let nextBookmark = menuItem("Next Bookmark", in: menu)
    let previousBookmark = menuItem("Previous Bookmark", in: menu)
    let clearBookmarks = menuItem("Clear All Bookmarks", in: menu)
    #expect(toggleBookmark?.action == #selector(DuckpadWindowController.performToggleBookmark(_:)))
    #expect(toggleBookmark?.keyEquivalent == f2)
    #expect(toggleBookmark?.keyEquivalentModifierMask == [.command])
    #expect(nextBookmark?.action == #selector(DuckpadWindowController.performNextBookmark(_:)))
    #expect(nextBookmark?.keyEquivalentModifierMask == [])
    #expect(previousBookmark?.action == #selector(DuckpadWindowController.performPreviousBookmark(_:)))
    #expect(previousBookmark?.keyEquivalentModifierMask == [.shift])
    #expect(clearBookmarks?.action == #selector(DuckpadWindowController.performClearBookmarks(_:)))
    #expect(clearBookmarks?.keyEquivalentModifierMask == [.command, .shift])
    if let toggleBookmark, let nextBookmark, let clearBookmarks {
        #expect(controller.validateMenuItem(toggleBookmark))
        #expect(!controller.validateMenuItem(nextBookmark))
        controller.performToggleBookmark(toggleBookmark)
        #expect(controller.validateMenuItem(nextBookmark))
        #expect(controller.validateMenuItem(clearBookmarks))
        controller.performClearBookmarks(clearBookmarks)
        #expect(!controller.validateMenuItem(nextBookmark))
    }

    let close = menuItem("Close Tab", in: menu)
    #expect(close?.action == #selector(DuckpadWindowController.performCloseActiveTab(_:)))
    #expect(close?.keyEquivalent == "w")
    #expect(close?.keyEquivalentModifierMask == [.command])

    let undoClose = menuItem("Undo Close Tab", in: menu)
    #expect(undoClose?.action == #selector(DuckpadWindowController.performRestoreLastClosedTab(_:)))
    #expect(undoClose?.keyEquivalent == "t")
    #expect(undoClose?.keyEquivalentModifierMask == [.command, .shift])
    if let undoClose { #expect(!controller.validateMenuItem(undoClose)) }

    let closedID = workspace.snapshot().tabs[0].id
    await controller.performClose(closedID).value
    if let undoClose {
        #expect(controller.validateMenuItem(undoClose))
        controller.performRestoreLastClosedTab(undoClose)
        for _ in 0..<200 where !workspace.snapshot().tabs.contains(where: { $0.id == closedID }) {
            await Task.yield()
        }
        #expect(workspace.snapshot().tabs.contains(where: { $0.id == closedID }))
        #expect(!controller.validateMenuItem(undoClose))
    }

    let openDocument = menuItem("Open Document…", in: menu)
    #expect(openDocument?.action == #selector(DuckpadWindowController.performShowDocumentSwitcher(_:)))
    #expect(openDocument?.keyEquivalent == "o")
    #expect(openDocument?.keyEquivalentModifierMask == [.command, .shift])
    if let openDocument { #expect(controller.validateMenuItem(openDocument)) }

    let bulkCloseItems: [(String, Selector)] = [
        ("Close All Tabs", #selector(DuckpadWindowController.performCloseAllTabs(_:))),
        ("Close Other Tabs", #selector(DuckpadWindowController.performCloseOtherTabs(_:))),
        ("Close Tabs to Left", #selector(DuckpadWindowController.performCloseTabsToLeft(_:))),
        ("Close Tabs to Right", #selector(DuckpadWindowController.performCloseTabsToRight(_:))),
        ("Close Unchanged Tabs", #selector(DuckpadWindowController.performCloseUnchangedTabs(_:))),
        ("Close Unpinned Tabs", #selector(DuckpadWindowController.performCloseUnpinnedTabs(_:))),
    ]
    for (title, selector) in bulkCloseItems {
        let item = menuItem(title, in: menu)
        #expect(item?.action == selector)
        #expect(item?.keyEquivalent.isEmpty == true)
    }
    if let closeOthers = menuItem("Close Other Tabs", in: menu),
       let closeLeft = menuItem("Close Tabs to Left", in: menu),
       let closeRight = menuItem("Close Tabs to Right", in: menu) {
        #expect(!controller.validateMenuItem(closeOthers))
        #expect(!controller.validateMenuItem(closeLeft))
        #expect(!controller.validateMenuItem(closeRight))
    }

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
    let languageChooser = menuItem("Choose Language…", in: menu)
    let commandPalette = menuItem("Command Palette…", in: menu)
    #expect(automaticLanguage?.action == #selector(DuckpadWindowController.performAutomaticLanguage(_:)))
    #expect(plainText?.action == #selector(DuckpadWindowController.performChooseLanguage(_:)))
    #expect(plainText?.representedObject as? String == LanguageID.plainText.rawValue)
    #expect(toggleComment?.action == #selector(DuckpadWindowController.performToggleLineComment(_:)))
    #expect(toggleComment?.keyEquivalent == "/")
    #expect(toggleComment?.keyEquivalentModifierMask == [.command])
    #expect(languageChooser?.action == #selector(DuckpadWindowController.performShowLanguageChooser(_:)))
    #expect(languageChooser?.keyEquivalent.isEmpty == true)
    #expect(languageChooser?.keyEquivalentModifierMask.isEmpty == true)
    #expect(commandPalette?.action == #selector(DuckpadWindowController.performShowCommandPalette(_:)))
    #expect(commandPalette?.keyEquivalent == "p")
    #expect(commandPalette?.keyEquivalentModifierMask == [.command, .shift])
    if let commandPalette { #expect(controller.validateMenuItem(commandPalette)) }

    let wordWrap = menuItem("Word Wrap", in: menu)
    let wrapSymbols = menuItem("Show Wrap Symbols", in: menu)
    let whitespace = menuItem("Show Whitespace", in: menu)
    let lineEndings = menuItem("Show Line Endings", in: menu)
    let zoomIn = menuItem("Zoom In", in: menu)
    let zoomOut = menuItem("Zoom Out", in: menu)
    let actualSize = menuItem("Actual Size", in: menu)
    let workspaceSidebar = menuItem("Workspace Sidebar", in: menu)
    let documentSymbols = menuItem("Document Symbols…", in: menu)
    let addWorkspaceFolder = menuItem("Add Folder to Workspace…", in: menu)
    let removeWorkspaceFolder = menuItem("Remove Folder from Workspace", in: menu)
    #expect(workspaceSidebar == nil)
    #expect(addWorkspaceFolder == nil)
    #expect(removeWorkspaceFolder == nil)
    #expect(controller.workspaceSidebarSmokeState().isVisible == false)
    #expect(controller.workspaceSidebarSmokeState().arrangedPaneCount == 1)
    #expect(documentSymbols?.action == #selector(DuckpadWindowController.performShowDocumentSymbols(_:)))
    #expect(documentSymbols?.keyEquivalent == "o")
    #expect(documentSymbols?.keyEquivalentModifierMask == [.command, .option])
    if let documentSymbols { #expect(!controller.validateMenuItem(documentSymbols)) }
    #expect(wordWrap?.action == #selector(DuckpadWindowController.performToggleWordWrap(_:)))
    #expect(wrapSymbols?.action == #selector(DuckpadWindowController.performToggleWrapMarker(_:)))
    #expect(whitespace?.action == #selector(DuckpadWindowController.performToggleWhitespace(_:)))
    #expect(lineEndings?.action == #selector(DuckpadWindowController.performToggleLineEndings(_:)))
    #expect(zoomIn?.keyEquivalent == "+")
    #expect(zoomOut?.keyEquivalent == "-")
    #expect(actualSize?.keyEquivalent == "0")
    for item in [zoomIn, zoomOut, actualSize].compactMap({ $0 }) {
        #expect(item.keyEquivalentModifierMask == [.command])
    }
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
    if let whitespace, let lineEndings, let zoomIn, let zoomOut, let actualSize {
        #expect(controller.validateMenuItem(whitespace))
        #expect(whitespace.state == .off)
        controller.performToggleWhitespace(whitespace)
        #expect(controller.validateMenuItem(whitespace))
        #expect(whitespace.state == .on)

        #expect(controller.validateMenuItem(lineEndings))
        controller.performToggleLineEndings(lineEndings)
        #expect(controller.validateMenuItem(lineEndings))
        #expect(lineEndings.state == .on)

        #expect(controller.validateMenuItem(zoomIn))
        #expect(controller.validateMenuItem(zoomOut))
        #expect(!controller.validateMenuItem(actualSize))
        controller.performZoomIn(zoomIn)
        #expect(controller.validateMenuItem(actualSize))
        controller.performResetZoom(actualSize)
        #expect(!controller.validateMenuItem(actualSize))
    }
    let splitRight = menuItem("Split Editor Right", in: menu)
    let splitDown = menuItem("Split Editor Down", in: menu)
    let focusOtherPane = menuItem("Focus Other Editor Pane", in: menu)
    let closeSplit = menuItem("Close Editor Split", in: menu)
    #expect(splitRight?.action == #selector(DuckpadWindowController.performSplitEditorRight(_:)))
    #expect(splitRight?.keyEquivalent == "\\")
    #expect(splitRight?.keyEquivalentModifierMask == [.command])
    #expect(splitDown?.action == #selector(DuckpadWindowController.performSplitEditorDown(_:)))
    #expect(splitDown?.keyEquivalentModifierMask == [.command, .option])
    #expect(focusOtherPane?.action == #selector(DuckpadWindowController.performFocusOtherEditorPane(_:)))
    #expect(focusOtherPane?.keyEquivalentModifierMask == [.command, .control])
    #expect(closeSplit?.action == #selector(DuckpadWindowController.performCloseEditorSplit(_:)))
    #expect(closeSplit?.keyEquivalentModifierMask == [.command, .shift])
    if let splitRight, let closeSplit {
        #expect(!controller.validateMenuItem(splitRight))
        #expect(!controller.validateMenuItem(closeSplit))
    }
}

@Test @MainActor func openRecentMenuUsesApplicationLifetimeTargetAndDisambiguatesNames() {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    let target = ApplicationMenuTargetSpy()
    let first = URL(fileURLWithPath: "/tmp/one/shared.txt")
    let second = URL(fileURLWithPath: "/var/one/shared.txt")
    let menu = DuckpadMainMenuFactory.make(
        target: controller,
        applicationTarget: target,
        recentDocumentURLs: [first, second]
    )
    let recent = menuItem("Open Recent", in: menu)?.submenu

    #expect(recent?.items.map(\.title) == ["shared.txt — tmp/one", "shared.txt — var/one", "", "Clear Menu"])
    let firstItem = recent?.items.first
    #expect(firstItem?.target === target)
    #expect(firstItem?.representedObject as? URL == first)
    if let firstItem, let action = firstItem.action {
        _ = NSApplication.shared.sendAction(action, to: firstItem.target, from: firstItem)
    }
    #expect(target.openedRecentURLs == [first])
    let clear = recent?.items.last
    if let clear, let action = clear.action {
        _ = NSApplication.shared.sendAction(action, to: clear.target, from: clear)
    }
    #expect(target.clearRecentRequests == 1)
}

@Test @MainActor func completionAndSymbolCommandsRouteThroughBoundedUseCase() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let editor = HostedLanguageEditorFake()
    let intelligence = DocumentIntelligenceUseCase(editor: editor, maximumDocumentBytes: 4_096)
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: editor,
        editorView: NSView(frame: .zero),
        documentIntelligenceUseCase: intelligence,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let buffer = try #require(workspace.snapshot().activeBuffer)
    editor.install(EditorTextSnapshot(
        bufferID: buffer.bufferID,
        revision: buffer.revision,
        text: "func alpha() {}\nalphabet alp"
    ))

    let menu = DuckpadMainMenuFactory.make(target: controller)
    let completion = try #require(menuItem("Complete Current Document Word", in: menu))
    let symbols = try #require(menuItem("Document Symbols…", in: menu))
    #expect(controller.validateMenuItem(completion))
    #expect(controller.validateMenuItem(symbols))

    controller.performCompleteCurrentDocumentWord(completion)
    for _ in 0..<500 where editor.presentedCompletionItems.isEmpty { await Task.yield() }
    #expect(Set(editor.presentedCompletionItems) == Set(["alpha", "alphabet"]))

    controller.performShowDocumentSymbols(symbols)
    for _ in 0..<500 where controller.symbolOutlinePanel.symbols.isEmpty { await Task.yield() }
    #expect(controller.symbolOutlinePanel.symbols.map(\.name) == ["alpha"])
    #expect(controller.beginTerminationReviewAdmission())
    #expect(editor.completionCancellationCount >= 1)
    #expect(editor.presentedCompletionItems.isEmpty)
    controller.cancelPreparedTerminationReview()
}

@Test @MainActor func symbolOutlineSearchMatchesNameKindLineAndDiacritics() {
    let symbols = [
        DocumentSymbol(name: "café", kind: .function, line: 3, range: .init(location: 0, length: 5)),
        DocumentSymbol(name: "Duck", kind: .type, line: 8, range: .init(location: 9, length: 4)),
    ]
    #expect(SymbolOutlineSearch.matchingIndices(in: symbols, query: "cafe function") == [0])
    #expect(SymbolOutlineSearch.matchingIndices(in: symbols, query: "type 8") == [1])
    #expect(SymbolOutlineSearch.matchingIndices(in: symbols, query: "missing").isEmpty)

    let panel = SymbolOutlinePanel()
    var activated: DocumentSymbol?
    panel.onActivate = { activated = $0 }
    panel.apply(symbols: symbols)
    panel.setQuery("Duck")
    #expect(panel.filteredSymbols == [symbols[1]])
    panel.activateSelectedResult()
    #expect(activated == symbols[1])
}

@Test @MainActor func terminationWaitsForAcceptedBulkClosePersistence() async {
    var restored = ScratchSession()
    let first = restored.addUntitled()
    _ = restored.addUntitled()
    let store = PresentationStore(session: restored)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    await store.armBlockingCommit()
    let closeTask = controller.performClose(first)
    await store.waitUntilCommitEntered()
    #expect(controller.beginTerminationReviewAdmission())

    var terminationFinished = false
    let termination = Task { @MainActor in
        let approved = await controller.continuePreparedTerminationReview()
        terminationFinished = true
        return approved
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(!terminationFinished)

    await store.releaseCommit()
    await closeTask.value
    #expect(await termination.value)
    #expect(terminationFinished)
    #expect(!workspace.snapshot().tabs.contains(where: { $0.id == first }))
}

@Test @MainActor func closeAdmittedImmediatelyBeforeTerminationStillCommitsBeforeApproval() async {
    var restored = ScratchSession()
    let admittedClose = restored.addUntitled()
    _ = restored.addUntitled()
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore(session: restored))
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    let closeTask = controller.performClose(admittedClose)
    #expect(controller.beginTerminationReviewAdmission())
    #expect(await controller.continuePreparedTerminationReview())
    await closeTask.value

    #expect(!workspace.snapshot().tabs.contains(where: { $0.id == admittedClose }))
}

@Test @MainActor func terminationCancellationKeepsAlreadyAdmittedCloseAndReopensInteraction() async throws {
    var restored = ScratchSession()
    let admittedClose = restored.addUntitled()
    let dirty = restored.addUntitled()
    _ = try restored.recordEdit(in: dirty, expectedRevision: 0)
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore(session: restored))
    let controller = DuckpadWindowController(
        workspace: workspace,
        dirtyDecisionPresenter: FixedDirtyDecisionPresenter(.cancel),
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    let closeTask = controller.performClose(admittedClose)
    #expect(controller.beginTerminationReviewAdmission())
    #expect(!(await controller.continuePreparedTerminationReview()))
    await closeTask.value

    #expect(!workspace.snapshot().tabs.contains(where: { $0.id == admittedClose }))
    #expect(workspace.snapshot().tabs.contains(where: { $0.id == dirty }))
    let newScratch = NSMenuItem(
        title: "New Scratch",
        action: #selector(DuckpadWindowController.performNewScratch(_:)),
        keyEquivalent: "n"
    )
    #expect(controller.validateMenuItem(newScratch))
}

@Test @MainActor func mainMenuBulkCloseRoutesStableScopeThroughSharedCoordinator() async {
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    _ = await workspace.addScratch()
    _ = await workspace.addScratch()
    let active = try! #require(workspace.snapshot().tabs.first(where: \.isActive)?.id)

    let item = try! #require(menuItem("Close Other Tabs", in: DuckpadMainMenuFactory.make(target: controller)))
    #expect(controller.validateMenuItem(item))
    controller.performCloseOtherTabs(item)
    for _ in 0..<1_000 where workspace.snapshot().tabs.count != 1
        || workspace.recentlyClosedTabCount != 2 {
        await Task.yield()
    }

    #expect(workspace.snapshot().tabs.map(\.id) == [active])
    #expect(workspace.recentlyClosedTabCount == 2)
    #expect(!controller.validateMenuItem(item))
}

@Test @MainActor func navigationPanelBindsSubmissionToThePresentedBuffer() async throws {
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let presenter = NavigationPresenterSpy()
    let controller = DuckpadWindowController(
        workspace: workspace,
        navigationPresenter: presenter,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    controller.editor.textView.insertText("first\nsecond\nthird", replacementRange: NSRange(location: 0, length: 0))
    controller.performGoToLine()
    #expect(presenter.linePosition?.lineCount == 3)

    _ = await workspace.addScratch()
    presenter.lineCompletion?(3, 1)
    #expect(controller.editor.navigationPosition?.line == 1)

    controller.editor.textView.insertText("한글🙂", replacementRange: NSRange(location: 0, length: 0))
    controller.performGoToOffset()
    #expect(presenter.offsetPosition?.utf8Length == "한글🙂".utf8.count)
    presenter.offsetCompletion?("한".utf8.count)
    #expect(controller.editor.navigationPosition?.utf8Offset == "한".utf8.count)
}

@Test @MainActor func newScratchShortcutActionAddsAndActivatesUntitledTab() async {
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let original = workspace.snapshot().tabs.first(where: \.isActive)?.id
    #expect(original != nil)

    controller.performNewScratch()
    for _ in 0..<200 where workspace.snapshot().tabs.count != 2 {
        try? await Task.sleep(for: .milliseconds(5))
    }
    await workspace.waitForPendingPersistence()
    let snapshot = workspace.snapshot()
    #expect(snapshot.tabs.count == 2)
    #expect(snapshot.tabs.first(where: \.isActive)?.id != original)
    #expect(snapshot.tabs.first(where: \.isActive)?.title == "new 2")
    #expect(controller.window?.firstResponder === controller.editor.textView)
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

@Test @MainActor func tabContextMenuPublishesEveryBulkCloseScope() throws {
    _ = NSApplication.shared
    let tabs = makeTabs(count: 4, activeIndex: 1)
    let (window, _, strip) = hostStrip(width: 700, height: 220, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    var actions: [TabContextAction] = []
    strip.onContextAction = { _, action in actions.append(action) }
    let menu = try #require(strip.contextMenu(for: tabs[1].id))
    let expected: [(String, TabCloseScope)] = [
        ("Close", .current),
        ("Close Others", .others),
        ("Close to Left", .left),
        ("Close to Right", .right),
        ("Close All", .all),
        ("Close Unchanged", .unchanged),
        ("Close Unpinned", .unpinned),
    ]
    for (title, scope) in expected {
        let index = try #require(menu.items.firstIndex(where: { $0.title == title }))
        menu.performActionForItem(at: index)
        #expect(actions.last == .close(scope))
    }
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

@Test @MainActor func tabTitlesNeverUseEllipsisAndLongNamesRemainScrollable() throws {
    let longTitle = "release-notes-" + String(repeating: "complete-name-", count: 30) + ".txt"
    let tab = TabSnapshot(
        id: TabID(),
        title: longTitle,
        isActive: true,
        isDirty: false,
        isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
    let (window, _, strip) = hostStrip(width: 260, height: 200, tabs: [tab])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }

    let path = IndexPath(item: 0, section: 0)
    let item = try #require(strip.hostedCollectionView.item(at: path))
    let title = try #require(descendantTextFields(of: item.view).first { $0.stringValue == longTitle })
    let frame = try #require(strip.flowLayout.layoutAttributesForItem(at: path)?.frame)

    #expect(title.lineBreakMode == .byClipping)
    #expect(title.cell?.truncatesLastVisibleLine == false)
    #expect(frame.width > strip.hostedScrollView.contentSize.width)
    #expect(strip.flowLayout.collectionViewContentSize.width >= frame.maxX)
}

@Test @MainActor func liveWindowKeepsLongTitleDocumentWidthAndHorizontalScrolling() throws {
    let longTitle = "release-notes-" + String(repeating: "complete-name-", count: 30) + ".txt"
    let longTab = TabSnapshot(
        id: TabID(), title: longTitle, isActive: true, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
    let normalTab = TabSnapshot(
        id: TabID(), title: "notes.txt", isActive: false, isDirty: false, isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
    let (window, root, strip) = hostStrip(width: 260, height: 200, tabs: [longTab, normalTab])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }

    window.orderFront(nil)
    root.layoutSubtreeIfNeeded()
    strip.layoutSubtreeIfNeeded()
    strip.hostedScrollView.layoutSubtreeIfNeeded()
    strip.hostedCollectionView.layoutSubtreeIfNeeded()

    let clipView = strip.hostedScrollView.contentView
    let layoutWidth = strip.flowLayout.collectionViewContentSize.width
    #expect(strip.hostedCollectionView.frame.width >= layoutWidth)
    #expect(strip.hostedScrollView.requiresHorizontalScroller)

    strip.hostedCollectionView.scroll(NSPoint(x: 300, y: 0))
    strip.hostedScrollView.reflectScrolledClipView(clipView)
    #expect(clipView.bounds.minX > 0)

    let changed = [
        TabSnapshot(
            id: longTab.id, title: longTab.title, isActive: false,
            isDirty: false, isPinned: false, buffer: longTab.buffer
        ),
        TabSnapshot(
            id: normalTab.id, title: normalTab.title, isActive: true,
            isDirty: false, isPinned: false, buffer: normalTab.buffer
        ),
    ]
    strip.apply(change: WorkspaceChange(
        snapshot: WorkspaceSnapshot(
            sessionID: SessionID(), tabs: changed, activeBuffer: normalTab.buffer,
            persistence: .pending, startup: .ready
        ),
        kind: .activeTabChanged(previousIndex: 0, currentIndex: 1)
    ))

    #expect(clipView.bounds.minX < 10)
    #expect(strip.selectedTabIsVisible)
}

@Test @MainActor func inactiveTabHoverUpdatesOnlyItsLocalAffordances() throws {
    let tabs = makeTabs(count: 2, activeIndex: 0)
    let (window, _, strip) = hostStrip(width: 500, height: 200, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let path = IndexPath(item: 1, section: 0)
    let item = try #require(strip.hostedCollectionView.item(at: path))
    let stableID = tabs[1].id.rawValue.uuidString.lowercased()
    let close = try #require(descendantButtons(of: item.view).first {
        $0.accessibilityIdentifier() == "duckpad.tab.close.\(stableID)"
    })
    let before = item.view.layer?.backgroundColor
    let event = try #require(NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
    ))

    item.view.updateTrackingAreas()
    #expect(item.view.trackingAreas.contains {
        $0.options.contains(.inVisibleRect) && $0.options.contains(.activeAlways)
    })
    #expect(close.frame.width >= 20)
    #expect(close.isHidden)
    item.view.mouseEntered(with: event)
    #expect(!close.isHidden)
    #expect(item.view.layer?.backgroundColor != before)
    item.view.mouseExited(with: event)
    #expect(close.isHidden)
    #expect(item.view.layer?.backgroundColor == before)
}

@Test @MainActor func tabChromeUsesExplicitDocumentDropdownWithoutNewButton() {
    let tabs = makeTabs(count: 64, activeIndex: 40)
    let (window, _, strip) = hostStrip(width: 900, height: 620, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }

    #expect(strip.documentSwitcher.title == "Documents (64)")
    #expect(strip.documentSwitcher.imagePosition == .imageTrailing)
    #expect(strip.documentSwitcher.accessibilityLabel() == "Open Documents")
    #expect(descendantButtons(of: strip).contains {
        $0.accessibilityIdentifier() == "duckpad.tab.add"
    } == false)
    #expect(strip.hostedScrollView.scrollerStyle == .overlay)
    #expect(strip.hostedScrollView.autohidesScrollers)
    #expect(strip.hostedScrollView.verticalScrollElasticity == .none)
    #expect(strip.hostedScrollView.horizontalScrollElasticity == .none)
}

@Test @MainActor func pendingTabCloseDeletesOneCollectionItemWithoutFullReload() {
    let original = makeTabs(count: 64, activeIndex: 40)
    let (window, _, strip) = hostStrip(width: 900, height: 620, tabs: original)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let removedIndex = 25
    var remaining = original
    let removed = remaining.remove(at: removedIndex)
    let snapshot = WorkspaceSnapshot(
        sessionID: SessionID(),
        tabs: remaining,
        activeBuffer: remaining.first(where: \.isActive)?.buffer,
        persistence: .pending,
        startup: .ready
    )
    let before = strip.updateMetrics

    let elapsed = ContinuousClock().measure {
        strip.apply(change: WorkspaceChange(
            snapshot: snapshot,
            kind: .tabRemovalPending(index: removedIndex)
        ))
    }

    #expect(strip.hostedCollectionView.numberOfItems(inSection: 0) == 63)
    #expect(strip.updateMetrics.fullReloads == before.fullReloads)
    #expect(strip.documentSwitcher.title == "Documents (63)")
    #expect(elapsed < .milliseconds(250))

    strip.apply(change: WorkspaceChange(
        snapshot: snapshot,
        kind: .tabRemoved(index: removedIndex, retiredBufferID: removed.buffer.bufferID)
    ))
    #expect(strip.hostedCollectionView.numberOfItems(inSection: 0) == 63)
    #expect(strip.updateMetrics.fullReloads == before.fullReloads)
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

@Test @MainActor func textViewFallbackBookmarksTrackEditsNavigateAndRecover() throws {
    let editor = TextViewEditorAdapter()
    let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let text = "zero\none\ntwo\nthree"
    editor.install(.init(bufferID: descriptor.bufferID, revision: 0, text: text))
    editor.display(descriptor)
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

    editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
    editor.toggleBookmarkAtCaret()
    editor.textView.setSelectedRange(NSRange(location: 13, length: 0))
    editor.toggleBookmarkAtCaret()
    #expect(editor.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [1, 3])
    #expect(editor.snapshot(for: descriptor.bufferID)?.revision == 0)
    #expect(editor.navigateToBookmark(forward: true))
    #expect(editor.textView.selectedRange().location == 5)
    #expect(editor.navigateToBookmark(forward: false))
    #expect(editor.textView.selectedRange().location == 13)

    editor.textView.insertText("new\n", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [2, 4])
    let recovery = try #require(editor.recoverySnapshot(for: descriptor.bufferID))
    let restored = TextViewEditorAdapter()
    restored.installRecovery(recovery)
    restored.display(.init(bufferID: descriptor.bufferID, revision: recovery.revision))
    #expect(restored.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [2, 4])
    restored.clearBookmarks()
    #expect(!restored.hasBookmarks)
    #expect(restored.textView.string == "new\n" + text)
}

@Test @MainActor func textViewFallbackBookmarksPreserveOtherDecorationsAndCRLFLineIdentity() throws {
    let editor = TextViewEditorAdapter()
    let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    editor.install(.init(bufferID: descriptor.bufferID, revision: 0, text: "zero\r\none\r\ntwo"))
    editor.display(descriptor)
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

    let decoration = NSColor.systemRed
    editor.textView.layoutManager?.addTemporaryAttribute(
        .backgroundColor,
        value: decoration,
        forCharacterRange: NSRange(location: 0, length: 1)
    )
    editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
    editor.toggleBookmarkAtCaret()
    let retained = editor.textView.layoutManager?.temporaryAttribute(
        .backgroundColor,
        atCharacterIndex: 0,
        effectiveRange: nil
    ) as? NSColor
    #expect(retained == decoration)

    editor.textView.insertText("", replacementRange: NSRange(location: 4, length: 1))
    #expect(editor.textView.string == "zero\none\r\ntwo")
    #expect(editor.recoveryCapture(for: descriptor.bufferID)?.viewState.bookmarkedLines == [2])
}

@Test @MainActor func textViewFallbackPerformsStandardEditCommandsWithOwnedUndo() throws {
    let editor = TextViewEditorAdapter()
    let bufferID = BufferID()
    editor.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
    editor.textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.canPerform(.undo))

    editor.perform(.undo)
    #expect(editor.textView.string == "")
    #expect(editor.canPerform(.redo))
    editor.perform(.redo)
    #expect(editor.textView.string == "abc")

    editor.perform(.selectAll)
    #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 3))
    #expect(editor.canPerform(.cut))
    #expect(editor.canPerform(.copy))
    editor.perform(.cut)
    #expect(editor.textView.string == "")
    #expect(!editor.canPerform(.delete))

    editor.perform(.undo)
    editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
    #expect(editor.canPerform(.delete))
    editor.perform(.delete)
    #expect(editor.textView.string == "ac")
}

@Test @MainActor func textViewFallbackPerformsAdvancedLineCommandsAsSingleUndoableEdits() {
    let editor = TextViewEditorAdapter()
    let bufferID = BufferID()
    editor.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
    editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: 0, text: "alpha\nbeta"))

    editor.textView.setSelectedRange(NSRange(location: 6, length: 4))
    editor.perform(.duplicateLine)
    #expect(editor.textView.string == "alpha\nbeta\nbeta")
    editor.perform(.undo)
    #expect(editor.textView.string == "alpha\nbeta")

    editor.textView.setSelectedRange(NSRange(location: 6, length: 4))
    editor.perform(.uppercase)
    #expect(editor.textView.string == "alpha\nBETA")
    editor.perform(.lowercase)
    #expect(editor.textView.string == "alpha\nbeta")
    editor.perform(.moveLineUp)
    #expect(editor.textView.string == "beta\nalpha")
    editor.perform(.moveLineDown)
    #expect(editor.textView.string == "alpha\nbeta")

    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.perform(.joinLines)
    #expect(editor.textView.string == "alpha beta")
    editor.perform(.undo)
    #expect(editor.textView.string == "alpha\nbeta")

    editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
    editor.perform(.indent)
    #expect(editor.textView.string == "\talpha\nbeta")
    editor.perform(.unindent)
    #expect(editor.textView.string == "alpha\nbeta")

    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: 20, text: "alpha  \nbeta\t"))
    editor.perform(.trimTrailingWhitespace)
    #expect(editor.textView.string == "alpha\nbeta")

    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: 30, text: "longer\nx"))
    editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
    editor.perform(.moveLineDown)
    #expect(editor.textView.string == "x\nlonger")
    #expect(editor.textView.selectedRange() == NSRange(location: 2, length: 6))
    editor.perform(.deleteLine)
    #expect(editor.textView.string == "x\n")

    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: 40, text: "a\n"))
    editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
    editor.perform(.moveLineUp)
    #expect(editor.textView.string == "\na")
    #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 1))

    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: 50, text: "한글\r\nx"))
    editor.textView.setSelectedRange(NSRange(location: 0, length: 2))
    editor.perform(.moveLineDown)
    #expect(editor.textView.string == "x\r\n한글")
    #expect(editor.textView.selectedRange() == NSRange(location: 3, length: 2))
    editor.perform(.deleteLine)
    #expect(editor.textView.string == "x\r\n")
}

@Test @MainActor func textViewFallbackRevisionExhaustionDisablesEveryMutationCommand() {
    let editor = TextViewEditorAdapter()
    let bufferID = BufferID()
    let descriptor = EditorBufferDescriptor(bufferID: bufferID, revision: .max)
    editor.display(descriptor)
    editor.install(EditorTextSnapshot(bufferID: bufferID, revision: .max, text: "locked"))
    editor.setInputEnabled(true)
    editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("replacement", forType: .string)
    let originalUndo = editor.textView.undoManager?.canUndo
    let originalRedo = editor.textView.undoManager?.canRedo

    #expect(!editor.textView.isEditable)
    #expect(editor.textView.isSelectable)
    for command in [
        EditorCommand.undo,
        .redo,
        .cut,
        .paste,
        .delete,
        .duplicateLine,
        .moveLineUp,
        .moveLineDown,
        .deleteLine,
        .joinLines,
        .uppercase,
        .lowercase,
        .indent,
        .unindent,
        .trimTrailingWhitespace,
    ] {
        #expect(!editor.canPerform(command))
        editor.perform(command)
    }

    #expect(editor.textView.string == "locked")
    #expect(editor.snapshot(for: bufferID)?.revision == .max)
    #expect(editor.textView.undoManager?.canUndo == originalUndo)
    #expect(editor.textView.undoManager?.canRedo == originalRedo)
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
    #expect(strip.documentSwitcher.updateMetrics.incrementalItemInspections == 1)
    #expect(elapsed < .milliseconds(250))
}

@Test @MainActor func activeTabChangeReloadsOnlyPreviousAndCurrentItems() {
    let tabs = makeTabs(count: 500, activeIndex: 0)
    let (window, _, strip) = hostStrip(width: 700, height: 400, tabs: tabs)
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    var changed = tabs
    changed[0] = TabSnapshot(
        id: changed[0].id, title: changed[0].title, isActive: false,
        isDirty: changed[0].isDirty, isPinned: changed[0].isPinned,
        buffer: changed[0].buffer
    )
    changed[249] = TabSnapshot(
        id: changed[249].id, title: changed[249].title, isActive: true,
        isDirty: changed[249].isDirty, isPinned: changed[249].isPinned,
        buffer: changed[249].buffer
    )
    let before = strip.updateMetrics
    let started = ContinuousClock.now
    strip.apply(change: WorkspaceChange(
        snapshot: WorkspaceSnapshot(
            sessionID: SessionID(), tabs: changed, activeBuffer: changed[249].buffer,
            persistence: .pending, startup: .ready
        ),
        kind: .activeTabChanged(previousIndex: 0, currentIndex: 249)
    ))
    let elapsed = started.duration(to: .now)

    #expect(strip.updateMetrics.fullReloads == before.fullReloads)
    #expect(strip.updateMetrics.itemReloads == before.itemReloads + 2)
    #expect(strip.hostedCollectionView.selectionIndexPaths == [IndexPath(item: 249, section: 0)])
    #expect(strip.selectedTabIsVisible)
    #expect(elapsed < .milliseconds(50))
}

@Test @MainActor func blockedActivationPublishesTheSelectedTabBeforeDiskCommitCompletes() async {
    var session = ScratchSession()
    for _ in 0..<50 { session.addUntitled() }
    let store = PresentationStore(session: session)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let targetIndex = 24
    let target = workspace.snapshot().tabs[targetIndex].id
    let before = controller.tabStrip.updateMetrics
    await store.armBlockingCommit()

    let activation = Task { await workspace.activate(tabID: target) }
    await store.waitUntilCommitEntered()

    #expect(workspace.snapshot().tabs[targetIndex].isActive)
    #expect(controller.tabStrip.hostedCollectionView.selectionIndexPaths == [
        IndexPath(item: targetIndex, section: 0),
    ])
    #expect(controller.tabStrip.updateMetrics.fullReloads == before.fullReloads)
    #expect(controller.tabStrip.updateMetrics.itemReloads == before.itemReloads + 2)

    await store.releaseCommit()
    #expect(await activation.value == .applied(.saved))
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

@Test @MainActor func compactChromeCollapsesEmptyBannerAndKeepsStatusOutsideEditor() async {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: PresentationStore())
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()

    let chrome = controller.workspaceChromeSmokeState()
    #expect(chrome.documentCount == 1)
    #expect(chrome.bannerHeight == 0)
    #expect(chrome.tabStripHeight == 34)
    #expect(chrome.statusBarHeight == 24)
    #expect(!chrome.editorOverlapsStatusBar)
    #expect(chrome.interactionsEnabled)
    #expect(chrome.languageStatusEnabled)
    #expect(chrome.extensionStatusEnabled)
    #expect(controller.tabStrip.documentSwitcher.accessibilityIdentifier() == "duckpad.tab.documents")
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
    let documentBefore = controller.tabStrip.documentSwitcher.updateMetrics
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
    #expect(controller.tabStrip.documentSwitcher.updateMetrics.fullRebuilds == documentBefore.fullRebuilds)
    #expect(controller.tabStrip.documentSwitcher.updateMetrics.itemUpdates == documentBefore.itemUpdates + 1)
    #expect(
        controller.tabStrip.documentSwitcher.updateMetrics.incrementalItemInspections
            == documentBefore.incrementalItemInspections + 1
    )
    #expect(elapsed < .milliseconds(250))
    await workspace.waitForPendingPersistence()
    #expect(controller.tabStrip.updateMetrics.fullReloads == before.fullReloads)
    #expect(controller.tabStrip.updateMetrics.itemReloads == before.itemReloads + 1)
    controller.close()
}

@Test @MainActor func terminationJoinsAcceptedUndoCloseBeforeApproval() async {
    let store = PresentationStore()
    let workspace = ScratchWorkspaceUseCase(store: store)
    let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    _ = await workspace.addScratch()
    let closedID = workspace.snapshot().tabs[0].id
    await controller.performClose(closedID).value
    #expect(workspace.canRestoreRecentlyClosedTab)

    await store.armBlockingCommit()
    controller.performRestoreLastClosedTab(nil)
    await store.waitUntilCommitEntered()
    #expect(controller.beginTerminationReviewAdmission())
    let approval = Task { @MainActor in await controller.continuePreparedTerminationReview() }
    await Task.yield()
    #expect(!workspace.snapshot().tabs.contains(where: { $0.id == closedID }))

    await store.releaseCommit()
    #expect(await approval.value)
    #expect(workspace.snapshot().tabs.contains(where: { $0.id == closedID }))
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
