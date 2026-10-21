import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct WorkspaceInteractionTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func host() async -> DuckpadWindowController {
        _ = NSApplication.shared
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-workspace-interaction-" + UUID().uuidString)
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: archive))
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), workspaceBrowserUseCase: browser, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        if !controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }
    @Test func findFromWorkspaceSelectsItsFilterWithoutOpeningDocumentFind() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let outline = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.workspace.outline" })
        let input = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.workspace.query" } as? NSTextField)
        #expect(input.isHiddenOrHasHiddenAncestor)
        input.stringValue = "keep this query"
        #expect(window.makeFirstResponder(outline))
        controller.performShowFind()
        #expect(input.currentEditor() != nil)
        #expect(input.currentEditor()?.selectedRange == NSRange(location: 0, length: input.stringValue.utf16.count))
        #expect(controller.searchPanel.isHidden)
        #expect(input.stringValue == "keep this query")
        controller.performShowFind()
        #expect(input.isHiddenOrHasHiddenAncestor)
        #expect(input.stringValue.isEmpty)
        #expect(window.firstResponder === outline)
    }
    @Test func literalControlFFromWorkspaceFocusesFilter() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        let all = views(try #require(window.contentView))
        let outline = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.outline" })
        let input = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.query" } as? NSTextField)
        #expect(input.isHiddenOrHasHiddenAncestor)
        #expect(window.makeFirstResponder(outline))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(window.performKeyEquivalent(with: event))
        #expect(input.currentEditor() != nil)
        #expect(controller.searchPanel.isHidden)
        #expect(!input.isHiddenOrHasHiddenAncestor)
        input.stringValue = "temporary filter"
        #expect(window.performKeyEquivalent(with: event))
        #expect(input.isHiddenOrHasHiddenAncestor)
        #expect(input.stringValue.isEmpty)
        #expect(window.firstResponder === outline)
    }
    @Test func emptyFilterHasNoReservedStatusSpace() throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 400))
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(views(sidebar).first { $0.accessibilityIdentifier() == "duckpad.workspace.header" })
        let scroll = try #require(sidebar.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(sidebar.search.isHidden)
        #expect(abs(scroll.frame.maxY - header.frame.minY) <= 1)
        #expect(sidebar.search.frame.height <= 34)
    }

    @Test func escapeClosesFilterAndCancelsPendingResults() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        let all = views(try #require(window.contentView))
        let sidebar = try #require(all.compactMap { $0 as? WorkspaceSidebarView }.first)
        let outline = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.outline" })
        let input = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.query" } as? NSTextField)
        let root = WorkspaceRoot(canonicalPath: "/fixture", displayName: "fixture")
        sidebar.apply(roots: [root])
        var completed = false
        var finishLoad: CheckedContinuation<Void, Never>?
        defer { finishLoad?.resume() }
        sidebar.search.onLoad = { _ in
            // Hold completion explicitly, even when the request is cancelled.
            await withCheckedContinuation { finishLoad = $0 }
            completed = true
            return .init(files: [], isTruncated: false, skippedDirectoryCount: 0)
        }
        #expect(window.makeFirstResponder(outline))
        controller.performShowFind()
        sidebar.search.setQuery("pending")
        let startedDeadline = ContinuousClock.now + .seconds(3)
        while finishLoad == nil, ContinuousClock.now < startedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(finishLoad != nil)
        let editor = try #require(input.currentEditor() as? NSTextView)
        #expect(sidebar.search.control(input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(sidebar.search.isHidden)
        #expect(sidebar.search.query.isEmpty)
        #expect(window.firstResponder === outline)
        #expect(!completed)
        finishLoad?.resume(); finishLoad = nil
        let completedDeadline = ContinuousClock.now + .seconds(3)
        while !completed, ContinuousClock.now < completedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed)
        let tree = try #require(outline as? NSOutlineView)
        #expect(tree.numberOfRows == 1)
        #expect(sidebar.search.query.isEmpty)
        #expect(sidebar.search.isHidden)
        controller.performShowFind()
        #expect(!sidebar.search.isHidden)
        #expect(window.makeFirstResponder(outline))
        outline.cancelOperation(nil)
        #expect(sidebar.search.isHidden)
        #expect(window.firstResponder === outline)
    }

    @Test func hidingDuringKoreanCompositionDoesNotRestartFilter() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        let all = views(try #require(window.contentView))
        let sidebar = try #require(all.compactMap { $0 as? WorkspaceSidebarView }.first)
        let outline = try #require(all.compactMap { $0 as? NSOutlineView }.first)
        let input = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.query" } as? NSTextField)
        var requests: [String] = []
        sidebar.search.onLoad = { query in
            requests.append(query)
            return .init(files: [], isTruncated: false, skippedDirectoryCount: 0)
        }
        #expect(window.makeFirstResponder(outline))
        controller.performShowFind()
        let editor = try #require(input.currentEditor() as? NSTextView)
        editor.setMarkedText("사용중", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: 0, length: 0))
        #expect(editor.hasMarkedText())
        controller.performShowFind()
        #expect(sidebar.search.isHidden)
        #expect(sidebar.search.query.isEmpty)
        #expect(window.firstResponder === outline)
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests.isEmpty)
        controller.performShowFind()
        #expect(input.stringValue.isEmpty)
        #expect(input.currentEditor()?.string.isEmpty == true)
    }

    @Test func compactFilterLayoutAcrossLocalesAndWidths() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        let all = views(try #require(window.contentView))
        let sidebar = try #require(all.compactMap { $0 as? WorkspaceSidebarView }.first)
        let outline = try #require(all.compactMap { $0 as? NSOutlineView }.first)
        let input = try #require(all.first { $0.accessibilityIdentifier() == "duckpad.workspace.query" } as? NSTextField)
        let split = try #require(sidebar.superview as? NSSplitView)
        let root = WorkspaceRoot(canonicalPath: "/fixture", displayName: "duckpad")
        sidebar.apply(roots: [root])
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
            .init(rootID: root.id, relativePath: "Sources", name: "Sources", kind: .directory),
            .init(rootID: root.id, relativePath: "README.md", name: "README.md", kind: .file),
        ])
        outline.expandItem(outline.item(atRow: 0))
        #expect(window.makeFirstResponder(outline))
        controller.performShowFind()
        for language in AppLanguage.allCases where language != .system {
            sidebar.refreshLocalization(catalog: .init(language: language))
            for width: CGFloat in [160, 220, 380] {
                split.setPosition(width, ofDividerAt: 0)
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(!sidebar.hasAmbiguousLayout)
                #expect(sidebar.search.frame.height == 34)
                #expect(input.frame.height == SearchInputField.preferredHeight)
                #expect(input.frame.width > 80)
                if let directory = ProcessInfo.processInfo.environment["DUCKPAD_WORKSPACE_INTERACTION_SNAPSHOTS"], width == 220 {
                    let bitmap = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                    sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("workspace-" + language.rawValue + ".png"))
                }
            }
        }
    }

    @Test func standaloneNavigationRestoreRecomputesHorizontalExtent() throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 400))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar
        defer { window.close() }
        let root = WorkspaceRoot(canonicalPath: "/fixture", displayName: "fixture")
        sidebar.apply(roots: [root])
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
            .init(rootID: root.id, relativePath: "folder", name: "folder", kind: .directory)
        ])
        let name = String(repeating: "wide-filename-", count: 12) + ".swift"
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "folder", entries: [
            .init(rootID: root.id, relativePath: "folder/" + name, name: name, kind: .file)
        ])
        sidebar.layoutSubtreeIfNeeded()
        let outline = try #require(views(sidebar).compactMap { $0 as? NSOutlineView }.first)
        let column = try #require(outline.tableColumns.first)
        let collapsedWidth = column.width
        sidebar.restoreNavigation(for: .init(id: root.id, canonicalPath: root.canonicalPath,
            displayName: root.displayName, isAvailable: true,
            expandedRelativePaths: ["", "folder"], selectedRelativePath: "folder/" + name))
        #expect(outline.numberOfRows == 3)
        #expect((outline.item(atRow: outline.selectedRow) as? WorkspaceSidebarNode)?.name == name)
        #expect(column.width > collapsedWidth + 200)
        let width = column.width
        outline.collapseItem(outline.item(atRow: 1))
        outline.expandItem(outline.item(atRow: 1))
        #expect(abs(column.width - width) < 1) // cached and first-time measurements agree
    }

    @Test func directoryExpansionAndCollapseDoNotAnimate() throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 400))
        let root = WorkspaceRoot(canonicalPath: "/fixture", displayName: "fixture")
        sidebar.apply(roots: [root])
        let outline = try #require(views(sidebar).compactMap { $0 as? NSOutlineView }.first)
        let item = try #require(outline.item(atRow: 0))
        var expandDuration: TimeInterval?, collapseDuration: TimeInterval?
        let a = NotificationCenter.default.addObserver(forName: NSOutlineView.itemWillExpandNotification, object: outline, queue: nil) { _ in
            MainActor.assumeIsolated { expandDuration = NSAnimationContext.current.duration }
        }
        let b = NotificationCenter.default.addObserver(forName: NSOutlineView.itemWillCollapseNotification, object: outline, queue: nil) { _ in
            MainActor.assumeIsolated { collapseDuration = NSAnimationContext.current.duration }
        }
        defer { NotificationCenter.default.removeObserver(a); NotificationCenter.default.removeObserver(b) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 5
            outline.expandItem(item)
            outline.collapseItem(item)
            #expect(context.duration == 5) // do not change animation settings outside the tree
        }
        #expect(expandDuration == 0)
        #expect(collapseDuration == 0)
    }

    @Test func findFromOutsideWorkspaceStillOpensDocumentSearch() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let field = NSTextField(frame: .init(x: 500, y: 100, width: 180, height: 26))
        content.addSubview(field)
        #expect(window.makeFirstResponder(field))
        controller.performShowFind()
        #expect(!controller.searchPanel.isHidden)
    }

    @Test func visibleSidebarHonorsWidthsAcrossLayoutAndWindowResize() async throws {
        let controller = await host(); defer { controller.close() }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let split = try #require(controller.editorGroupWorkspace.superview as? NSSplitView)
        let sidebar = try #require(split.arrangedSubviews.first as? WorkspaceSidebarView)
        for width: CGFloat in [220, 300, 180, 360] {
            split.setPosition(width, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(sidebar.frame.width - width) <= 1)
        }
        var frame = window.frame; frame.size.width += 100
        window.setFrame(frame, display: true); window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(sidebar.frame.width - 360) <= 1)
        controller.performToggleWorkspaceSidebar(); controller.performToggleWorkspaceSidebar()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(sidebar.frame.width - 360) <= 1)
    }

}
