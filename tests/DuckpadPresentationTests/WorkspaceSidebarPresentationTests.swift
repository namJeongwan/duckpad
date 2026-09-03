import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

private final class WorkspaceWeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

private actor PresentationWorkspaceRootStore: WorkspaceRootStore {
    private var roots: [WorkspaceRoot] = []
    private var blockLoad = false
    private var loadEntered = false
    private var releaseLoad = false

    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] {
        loadEntered = true
        while blockLoad && !releaseLoad { await Task.yield() }
        return roots
    }

    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        let root = WorkspaceRoot(canonicalPath: url.path, displayName: url.lastPathComponent)
        roots.append(root)
        return root
    }

    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) {
        roots.removeAll { $0.id == id }
    }

    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] { [] }

    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        throw .invalidPath(entry.relativePath)
    }

    func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        guard let root = roots.first(where: { $0.id == rootID }) else { throw .unknownRoot(rootID) }
        return root
    }

    func armBlockedLoad() { blockLoad = true; loadEntered = false; releaseLoad = false }
    func waitForLoad() async { while !loadEntered { await Task.yield() } }
    func releaseBlockedLoad() { releaseLoad = true }
}

@MainActor
private final class BlockingWorkspacePanel: FilePanelPresenting {
    private(set) var workspaceRequests = 0
    private(set) var cancellationRequests = 0
    var release = false

    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL? {
        workspaceRequests += 1
        while !release { await Task.yield() }
        return URL(fileURLWithPath: "/tmp/ignored", isDirectory: true)
    }
    func cancelOutstandingPanels() { cancellationRequests += 1 }
}

@Test @MainActor func workspaceSidebarLoadsChildrenPersistsExpansionAndRoutesContextActions() {
    _ = NSApplication.shared
    let root = WorkspaceRoot(
        canonicalPath: "/tmp/duckpad-workspace",
        displayName: "duckpad-workspace"
    )
    let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
    #expect(sidebar.apply(roots: [root]))

    let outline = sidebar.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSOutlineView
    let rootNode = outline.flatMap { sidebar.outlineView($0, child: 0, ofItem: nil) as? WorkspaceSidebarNode }
    var loaded: (WorkspaceRootID, String)?
    sidebar.onLoadChildren = { loaded = ($0, $1) }
    sidebar.outlineViewItemWillExpand(Notification(
        name: NSOutlineView.itemWillExpandNotification,
        object: outline,
        userInfo: ["NSObject": rootNode as Any]
    ))
    #expect(loaded?.0 == root.id)
    #expect(loaded?.1 == "")

    sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
        WorkspaceBrowserEntry(rootID: root.id, relativePath: "Sources", name: "Sources", kind: .directory),
        WorkspaceBrowserEntry(rootID: root.id, relativePath: "notes.txt", name: "notes.txt", kind: .file),
    ])
    var navigation: (WorkspaceRootID, [String], String?)?
    sidebar.onNavigationChange = { navigation = ($0, $1, $2) }
    if let outline, let rootNode {
        outline.expandItem(rootNode)
        sidebar.outlineViewItemDidExpand(Notification(
            name: NSOutlineView.itemDidExpandNotification,
            object: outline,
            userInfo: ["NSObject": rootNode]
        ))
    }
    #expect(navigation?.0 == root.id)
    #expect(navigation?.1.contains("") == true)

    var opened: WorkspaceBrowserEntry?
    sidebar.onOpenFile = { opened = $0 }
    if let outline,
       let fileRow = (0..<outline.numberOfRows).first(where: {
           (outline.item(atRow: $0) as? WorkspaceSidebarNode)?.relativePath == "notes.txt"
       }),
       let returnEvent = NSEvent.keyEvent(
           with: .keyDown,
           location: .zero,
           modifierFlags: [],
           timestamp: 0,
           windowNumber: 0,
           context: nil,
           characters: "\r",
           charactersIgnoringModifiers: "\r",
           isARepeat: false,
           keyCode: 36
       ) {
        outline.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        outline.keyDown(with: returnEvent)
    }
    #expect(opened?.relativePath == "notes.txt")

    var revealed: String?
    var removed: WorkspaceRootID?
    sidebar.onRevealPath = { revealed = $0 }
    sidebar.onRemoveRoot = { removed = $0 }
    if let outline {
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        guard let menu = outline.menu else {
            Issue.record("Workspace outline must expose a context menu")
            return
        }
        sidebar.menuNeedsUpdate(menu)
        let reveal = menu.items.first(where: { $0.title == "Reveal in Finder" })
        let remove = menu.items.first(where: { $0.title == "Remove Folder from Workspace" })
        if let reveal { _ = NSApp.sendAction(reveal.action!, to: reveal.target, from: reveal) }
        if let remove { _ = NSApp.sendAction(remove.action!, to: remove.target, from: remove) }
    }
    #expect(revealed == root.canonicalPath)
    #expect(removed == root.id)
}

@Test @MainActor func workspaceCommandsStayDisabledUntilRootRestoreIsReady() async {
    _ = NSApplication.shared
    let rootStore = PresentationWorkspaceRootStore()
    await rootStore.armBlockedLoad()
    let browser = WorkspaceBrowserUseCase(store: rootStore)
    let panel = BlockingWorkspacePanel()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let controller = DuckpadWindowController(
        workspace: workspace,
        filePanels: panel,
        workspaceBrowserUseCase: browser,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await rootStore.waitForLoad()
    let item = NSMenuItem(
        title: "Add Folder",
        action: #selector(DuckpadWindowController.performAddWorkspaceFolder(_:)),
        keyEquivalent: ""
    )
    #expect(!controller.validateMenuItem(item))
    controller.performAddWorkspaceFolder(item)
    for _ in 0..<20 { await Task.yield() }
    #expect(panel.workspaceRequests == 0)

    await rootStore.releaseBlockedLoad()
    for _ in 0..<1_000 where !browser.acceptsCommands { await Task.yield() }
    #expect(controller.validateMenuItem(item))
}

@Test @MainActor func closeAndTerminationDetachCancellationIgnoringWorkspacePanel() async {
    _ = NSApplication.shared
    let rootStore = PresentationWorkspaceRootStore()
    let browser = WorkspaceBrowserUseCase(store: rootStore)
    let panel = BlockingWorkspacePanel()
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let coordinator = ApplicationTerminationCoordinator()
    var controller: DuckpadWindowController? = DuckpadWindowController(
        workspace: workspace,
        filePanels: panel,
        terminationCoordinator: coordinator,
        workspaceBrowserUseCase: browser,
        automaticallyStarts: false
    )
    controller?.start()
    await controller?.waitForStartup()
    for _ in 0..<1_000 where !browser.acceptsCommands { await Task.yield() }
    controller?.performAddWorkspaceFolder(nil)
    for _ in 0..<1_000 where panel.workspaceRequests == 0 { await Task.yield() }
    #expect(controller?.requiresTerminationReview == true)

    var terminationReply: Bool?
    let response = coordinator.applicationShouldTerminate { terminationReply = $0 }
    #expect(response == .terminateLater)
    for _ in 0..<1_000 where terminationReply == nil { await Task.yield() }
    #expect(terminationReply == true)
    #expect(panel.cancellationRequests == 1)

    let weakController = WorkspaceWeakBox(controller)
    let weakWindow = WorkspaceWeakBox(controller?.window)
    controller?.close()
    controller = nil
    for _ in 0..<1_000 where weakController.value != nil || weakWindow.value != nil { await Task.yield() }
    #expect(weakController.value == nil)
    #expect(weakWindow.value == nil)
    panel.release = true
}
