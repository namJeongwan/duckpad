import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
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

@Test @MainActor func externalFolderOpenAddsWorkspaceRootAndRevealsHiddenSidebar() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-cli-folder-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let browser = WorkspaceBrowserUseCase(store: PresentationWorkspaceRootStore())
    let controller = DuckpadWindowController(
        workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
        previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
        workspaceBrowserUseCase: browser,
        automaticallyStarts: false
    )
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    if controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
    let opened = await withCheckedContinuation { continuation in
        controller.openExternalURLs([directory]) { continuation.resume(returning: $0) }
    }
    #expect(opened)
    #expect(browser.roots.map(\.canonicalPath) == [directory.path])
    #expect(controller.workspaceSidebarSmokeState().isVisible)
    let reopened = await withCheckedContinuation { continuation in
        controller.openExternalURLs([directory]) { continuation.resume(returning: $0) }
    }
    #expect(reopened)
    #expect(browser.roots.count == 1)
    let link = directory.appendingPathComponent("workspace-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    let linked = await withCheckedContinuation { continuation in
        controller.openExternalURLs([link]) { continuation.resume(returning: $0) }
    }
    #expect(linked)
    #expect(browser.roots.count == 1)
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
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
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
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
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

@Test @MainActor func workspaceSidebarShowsFullNamesAndKeepsLoadedTreeWhenAddingRoots() throws {
    _ = NSApplication.shared
    let root = WorkspaceRoot(canonicalPath: "/tmp/project", displayName: "project")
    let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 500))
    let host = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView = sidebar
    defer { host.close() }
    sidebar.apply(roots: [root])
    let scroll = try #require(sidebar.subviews.compactMap { $0 as? NSScrollView }.first)
    let outline = try #require(scroll.documentView as? NSOutlineView)
    let node = sidebar.outlineView(outline, child: 0, ofItem: nil)
    let name = "very-long-workspace-document-name-with-Korean-한글-and-spaces.json"
    sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
        .init(rootID: root.id, relativePath: name, name: name, kind: .file),
    ])
    outline.expandItem(node)
    outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    sidebar.layoutSubtreeIfNeeded()
    let selectedRow = try #require(outline.rowView(atRow: 1, makeIfNecessary: true))
    selectedRow.isEmphasized = true
    if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        #expect(selectedRow.interiorBackgroundStyle == .normal)
    }
    #expect(scroll.hasHorizontalScroller)
    #expect(outline.tableColumns[0].width > scroll.contentSize.width)
    let cell = try #require(sidebar.outlineView(outline, viewFor: outline.tableColumns[0], item: outline.item(atRow: 1)!) as? NSTableCellView)
    #expect(cell.textField?.lineBreakMode == .byClipping)
    let displayedCell = try #require(outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
    let label = try #require(displayedCell.textField)
    #expect(!label.allowsExpansionToolTips)
    #expect(label.bounds.width > label.visibleRect.width)
    #expect(label.expansionFrame(withFrame: label.bounds).width > label.visibleRect.width)
    let rootCell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    let rootLabel = try #require(rootCell.textField)
    #expect(rootLabel.expansionFrame(withFrame: rootLabel.bounds).isEmpty)
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil,
        eventNumber: 0, trackingNumber: 0, userData: nil))
    #expect(host.makeFirstResponder(outline))
    let responder = host.firstResponder
    label.mouseEntered(with: entered)
    let expansion = try #require(host.childWindows?.first {
        $0.accessibilityIdentifier() == "duckpad.workspace.filename-expansion"
    })
    #expect(expansion.isVisible)
    #expect(expansion.ignoresMouseEvents)
    #expect((expansion.contentView?.subviews.first as? NSTextField)?.stringValue == name)
    let textFrame = host.convertToScreen(label.convert(label.bounds, to: nil))
    #expect(abs(expansion.frame.midY - textFrame.midY) < 0.5)
    #expect(host.firstResponder === responder)
    label.mouseExited(with: entered)
    #expect(host.childWindows?.isEmpty != false)
    rootLabel.mouseEntered(with: entered)
    #expect(host.childWindows?.isEmpty != false)
    let expectedIcon = MaterialFileIconTheme.shared.icon(for: name, appearance: sidebar.effectiveAppearance)
    #expect(cell.imageView?.image === expectedIcon.image)
    let second = WorkspaceRoot(canonicalPath: "/tmp/second", displayName: "second")
    scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(label.expansionFrame(withFrame: label.bounds).width > label.visibleRect.width)
    label.mouseEntered(with: entered)
    #expect(host.childWindows?.first?.isVisible == true)
    scroll.contentView.scroll(to: NSPoint(x: 110, y: 0))
    #expect(host.childWindows?.isEmpty != false)
    scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
    sidebar.apply(roots: [root, second])
    sidebar.layoutSubtreeIfNeeded()
    #expect(outline.isItemExpanded(node))
    #expect(outline.numberOfRows == 3)
    #expect(scroll.contentView.bounds.origin.x == 100)
    #expect((outline.item(atRow: outline.selectedRow) as? WorkspaceSidebarNode)?.relativePath == name)
    #expect(outline.tableColumns[0].width > scroll.contentSize.width)
    let reloadedCell = try #require(outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
    #expect(reloadedCell.toolTip == nil)
    #expect(reloadedCell.imageView?.toolTip == name)
    reloadedCell.textField?.mouseEntered(with: entered)
    #expect(host.childWindows?.first?.isVisible == true)
    host.close()
    #expect(host.childWindows?.isEmpty != false)
}

@Test @MainActor func workspaceOpenCloseCommandsAreDiscoverableAndPreserveDocuments() async throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let browser = WorkspaceBrowserUseCase(store: PresentationWorkspaceRootStore())
    let controller = DuckpadWindowController(workspace: workspace,
        previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
        workspaceBrowserUseCase: browser, automaticallyStarts: false)
    defer { controller.close() }
    controller.start()
    await controller.waitForStartup()
    let before = workspace.snapshot()
    #expect(controller.commandBar.subviews.compactMap { $0 as? NSButton }.contains {
        $0.accessibilityIdentifier() == "duckpad.workspace.toggle"
    })
    let menu = DuckpadMainMenuFactory.make(target: controller)
    func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    let all = items(menu)
    #expect(all.contains { $0.action == #selector(DuckpadWindowController.performAddWorkspaceFolder(_:)) })
    #expect(all.contains { $0.action == #selector(DuckpadWindowController.performRemoveWorkspaceFolder(_:)) })
    let toggle = try #require(all.first { $0.action == #selector(DuckpadWindowController.performToggleWorkspaceSidebar(_:)) })
    #expect(toggle.keyEquivalent == "b")
    #expect(toggle.keyEquivalentModifierMask == [.command])
    let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
        context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
    #expect(menu.performKeyEquivalent(with: shortcut))
    #expect(controller.workspaceSidebarSmokeState().isVisible)
    let content = try #require(controller.window?.contentView)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let close = try #require(descendants(content).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "duckpad.workspace.close"
    })
    _ = close.sendAction(close.action, to: close.target)
    #expect(!controller.workspaceSidebarSmokeState().isVisible)
    let open = try #require(controller.commandBar.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "duckpad.workspace.toggle"
    })
    let window = try #require(controller.window)
    #expect(window.makeFirstResponder(open))
    _ = open.sendAction(open.action, to: open.target)
    #expect((window.firstResponder as? NSView)?.isDescendant(of: controller.editorGroupWorkspace.primaryPane.editorHostView) == true)
    #expect(controller.workspaceSidebarSmokeState().isVisible)
    #expect(workspace.snapshot().tabs == before.tabs)
    for language in AppLanguage.allCases where language != .system {
        let catalog = LocalizationCatalog(language: language)
        controller.refreshLocalization(catalog: catalog)
        #expect(open.accessibilityLabel() == catalog.text("Hide Workspace"))
        #expect(close.accessibilityLabel() == catalog.text("Hide Workspace"))
        controller.performToggleWorkspaceSidebar(toggle)
        #expect(open.accessibilityLabel() == catalog.text("Show Workspace"))
        _ = open.sendAction(open.action, to: open.target)
    }
}

@Test @MainActor func workspaceSidebarKeepsChosenLanguageAfterReloadAndInContextMenu() throws {
    _ = NSApplication.shared
    let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 360))
    let host = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView = sidebar
    defer { host.close() }
    let root = WorkspaceRoot(canonicalPath: "/tmp/project", displayName: "project")
    let outline = try #require(sidebar.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSOutlineView)
    let header = try #require(sidebar.subviews.first { $0.accessibilityIdentifier() == "duckpad.workspace.header" })
    let title = try #require(header.subviews.compactMap { $0 as? NSTextField }.first)
    for language in AppLanguage.allCases where language != .system {
        let catalog = LocalizationCatalog(language: language)
        sidebar.refreshLocalization(catalog: catalog)
        sidebar.apply(roots: [root])
        #expect(title.stringValue == catalog.text("Workspace"))
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = try #require(outline.menu)
        sidebar.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == catalog.text("Reveal in Finder"))
        #expect(menu.items.last?.title == catalog.text("Remove Folder from Workspace"))
        sidebar.applyChildrenFailure(rootID: root.id, relativeDirectory: "", failure: .unavailableRoot(root.id))
        #expect(title.stringValue == catalog.text("Workspace ⚠"))
        sidebar.apply(roots: [root])
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
            .init(rootID: root.id, relativePath: "a.json", name: "a.json", kind: .file),
            .init(rootID: root.id, relativePath: "script.rb", name: "script.rb", kind: .file),
            .init(rootID: root.id, relativePath: "Sources", name: "Sources", kind: .directory),
        ])
        outline.expandItem(sidebar.outlineView(outline, child: 0, ofItem: nil))
        sidebar.layoutSubtreeIfNeeded()
        for width: CGFloat in [160, 260] {
            host.setContentSize(NSSize(width: width, height: 360))
            sidebar.layoutSubtreeIfNeeded()
            let buttons = header.subviews.compactMap { $0 as? NSButton }
            let firstButtonX = try #require(buttons.map { $0.frame.minX }.min())
            #expect(title.frame.maxX <= firstButtonX - 4)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_WORKSPACE_SNAPSHOTS"] {
                let destination = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    host.appearance = NSAppearance(named: appearance)
                    host.makeKeyAndOrderFront(nil)
                    outline.rowView(atRow: 0, makeIfNecessary: true)?.isEmphasized = true
                    sidebar.layoutSubtreeIfNeeded()
                    let bitmap = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                    sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
                    let file = "\(language.rawValue)-\(Int(width))-\(appearance.rawValue)-workspace.png"
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(file))
                }
            }
        }
    }
}

@Test @MainActor func workspaceSidebarDividerCanResizeWithoutChangingDocuments() throws {
    _ = NSApplication.shared
    let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
    let controller = DuckpadWindowController(
        workspace: workspace,
        previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
        automaticallyStarts: false
    )
    defer { controller.close() }
    let window = try #require(controller.window)
    let split = try #require(controller.editorGroupWorkspace.superview as? NSSplitView)
    if !controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
    window.contentView?.layoutSubtreeIfNeeded()
    let sidebar = try #require(split.arrangedSubviews.first as? WorkspaceSidebarView)
    let before = workspace.snapshot().tabs
    for width: CGFloat in [320, 180, 360] {
        split.setPosition(width, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(sidebar.frame.width - width) <= 1)
    }
    controller.performToggleWorkspaceSidebar()
    controller.performToggleWorkspaceSidebar()
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(abs(sidebar.frame.width - 360) <= 1)
    let scroll = try #require(sidebar.subviews.compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.scrollerStyle == .overlay)
    window.appearance = NSAppearance(named: .darkAqua)
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
        let actual = split.dividerColor.usingColorSpace(.sRGB)
        let native = NSSplitView(frame: .zero)
        native.dividerStyle = split.dividerStyle
        let color = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? native.dividerColor : WorkspaceColors.border
        let expected = color.usingColorSpace(.sRGB)
        #expect(actual != nil && expected != nil)
        if let actual, let expected {
            #expect(abs(actual.redComponent - expected.redComponent) < 0.01)
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.01)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.01)
        }
    }
    let drawnRect = NSRect(x: 360, y: 0, width: 1, height: 100)
    let hitRect = try #require(split.delegate?.splitView?(split, effectiveRect: drawnRect,
        forDrawnRect: drawnRect, ofDividerAt: 0))
    #expect(hitRect.minX <= drawnRect.minX - 3 && hitRect.maxX >= drawnRect.maxX + 3)
    #expect(window.styleMask.contains(.resizable))
    let originalSize = window.frame.size
    var resized = window.frame
    resized.size.width += 100
    resized.size.height += 60
    window.setFrame(resized, display: true)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.frame.width == originalSize.width + 100)
    #expect(window.frame.height == originalSize.height + 60)
    #expect(abs(split.frame.width - window.contentLayoutRect.width) <= 1)
    #expect(workspace.snapshot().tabs == before)
}
