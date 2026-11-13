import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct WorkspaceRefreshTests {
    @MainActor private final class Fixture {
        let directory: URL
        let project: URL
        let browser: WorkspaceBrowserUseCase
        let workspace: ScratchWorkspaceUseCase
        let editor: ScintillaEditorAdapter
        let controller: DuckpadWindowController
        let sidebar: WorkspaceSidebarView
        let outline: NSOutlineView
        init(waitForInitialListing: Bool = true, decorateStore: (any WorkspaceRootStore) -> any WorkspaceRootStore = { $0 }) async throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-tree-refresh-" + UUID().uuidString)
            project = directory.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: project.appendingPathComponent("src/keep.txt"))
            try Data("delete".utf8).write(to: project.appendingPathComponent("src/remove.txt"))
            try Data("rename".utf8).write(to: project.appendingPathComponent("src/old-name.txt"))
            let store = LocalWorkspaceRootStore(archiveURL: directory.appendingPathComponent("roots.json"))
            _ = try await store.addRoot(project)
            browser = WorkspaceBrowserUseCase(store: decorateStore(store))
            workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
            editor = ScintillaEditorAdapter()
            controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
                markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
                workspaceBrowserUseCase: browser, automaticallyStarts: false)
            controller.start(); await controller.waitForStartup()
            if !controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
            let content = try #require(controller.window?.contentView)
            sidebar = try #require(WorkspaceRefreshTests.views(content).compactMap { $0 as? WorkspaceSidebarView }.first)
            outline = try #require(WorkspaceRefreshTests.views(content).compactMap { $0 as? NSOutlineView }.first)
            if waitForInitialListing { try await WorkspaceRefreshTests.wait { self.node("src") != nil } }
        }
        func node(_ path: String) -> WorkspaceSidebarNode? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? WorkspaceSidebarNode }.first { $0.relativePath == path }
        }
        func refresh() throws {
            let button = try #require(WorkspaceRefreshTests.views(sidebar).first { $0.accessibilityIdentifier() == "duckpad.workspace.refresh" } as? NSButton)
            #expect(button.isEnabled); button.performClick(nil)
        }
        func close() {
            controller.close(); editor.invalidate(); try? FileManager.default.removeItem(at: directory)
        }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Workspace refresh did not finish")
    }

    @Test func refreshReadsExternalChangesAndPreservesExpandedSelectionAndUnsavedDocument() async throws {
        let fixture = try await Fixture(); defer { fixture.close() }
        let folder = try #require(fixture.node("src"))
        fixture.outline.expandItem(folder)
        try await Self.wait { fixture.node("src/keep.txt") != nil }
        let selected = try #require(fixture.node("src/keep.txt"))
        fixture.outline.selectRowIndexes(IndexSet(integer: fixture.outline.row(forItem: selected)), byExtendingSelection: false)
        let native = try #require(fixture.editor.activeScintillaView)
        native.insertCommittedText("미저장 문서 🦆")
        let before = fixture.workspace.snapshot()
        #expect(before.tabs.contains { $0.isDirty })
        let bytes = native.contentUTF8
        try Data("new".utf8).write(to: fixture.project.appendingPathComponent("src/added.txt"))
        try FileManager.default.removeItem(at: fixture.project.appendingPathComponent("src/remove.txt"))
        try FileManager.default.moveItem(at: fixture.project.appendingPathComponent("src/old-name.txt"),
            to: fixture.project.appendingPathComponent("src/new-name.txt"))
        #expect(fixture.node("src/added.txt") == nil)
        #expect(fixture.node("src/remove.txt") != nil)
        try fixture.refresh()
        try await Self.wait {
            fixture.node("src/added.txt") != nil && fixture.node("src/remove.txt") == nil &&
            fixture.node("src/old-name.txt") == nil && fixture.node("src/new-name.txt") != nil
        }
        #expect(fixture.outline.isItemExpanded(folder))
        #expect(fixture.outline.item(atRow: fixture.outline.selectedRow) as? WorkspaceSidebarNode === selected)
        #expect(native.contentUTF8 == bytes)
        #expect(fixture.workspace.snapshot().tabs == before.tabs)
        #expect(fixture.workspace.snapshot().activeBuffer == before.activeBuffer)
    }

    @Test func refreshUpdatesAnActiveFilenameFilterWithoutClearingItsQuery() async throws {
        let fixture = try await Fixture(); defer { fixture.close() }
        #expect(fixture.sidebar.toggleFilter())
        fixture.sidebar.search.setQuery("external")
        try await Task.sleep(for: .milliseconds(200))
        try Data("new".utf8).write(to: fixture.project.appendingPathComponent("external.txt"))
        #expect(fixture.node("external.txt") == nil)
        try fixture.refresh()
        try await Self.wait { fixture.node("external.txt") != nil }
        #expect(fixture.sidebar.search.query == "external")
        #expect(!fixture.sidebar.search.isHidden)
    }

    @Test func refreshControlUsesEverySupportedLocaleAndDisablesWithoutRoots() throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 200, height: 400))
        let button = try #require(Self.views(sidebar).first { $0.accessibilityIdentifier() == "duckpad.workspace.refresh" } as? NSButton)
        sidebar.apply(roots: [])
        #expect(!button.isEnabled)
        for language in AppLanguage.allCases {
            let catalog = LocalizationCatalog(language: language)
            sidebar.refreshLocalization(catalog: catalog)
            #expect(button.toolTip == catalog.text("Refresh"))
            #expect(button.accessibilityLabel() == catalog.text("Refresh"))
            let menu = try #require(Self.views(sidebar).compactMap { $0 as? NSOutlineView }.first?.menu)
            sidebar.menuNeedsUpdate(menu)
            #expect(menu.items.last?.title == catalog.text("Refresh"))
            #expect(menu.items.last?.isEnabled == false)
        }
    }

    @Test(arguments: [false, true])
    func olderDirectorySuccessOrFailureCannotReplaceRefreshedContents(fails: Bool) async throws {
        var gate: RefreshGatedRootStore!
        let fixture = try await Fixture { store in
            let gated = RefreshGatedRootStore(base: store)
            gate = gated
            return gated
        }
        defer { fixture.close(); Task { await gate.release() } }
        let root = try #require(fixture.browser.roots.first)
        await gate.arm(fails: fails)
        fixture.sidebar.onLoadChildren?(root.id, "")
        for _ in 0..<300 {
            if await gate.hasPendingRead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await gate.hasPendingRead)
        try Data("new".utf8).write(to: fixture.project.appendingPathComponent("external.txt"))
        try fixture.refresh()
        try await Self.wait { fixture.node("external.txt") != nil }
        await gate.release()
        // Let the cancellation-ignoring response reach the actual controller route.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.node("external.txt") != nil)
        let title = try #require(Self.views(fixture.sidebar).compactMap { $0 as? NSTextField }.first)
        #expect(!title.stringValue.contains("⚠"))
    }

    @Test(arguments: [false, true])
    func refreshDuringInitialListingRestartsSavedNavigation(repeated: Bool) async throws {
        var gate: RefreshGatedRootStore!
        let fixture = try await Fixture(waitForInitialListing: false) { store in
            let gated = RefreshGatedRootStore(base: store, holdFirstRead: true)
            gate = gated
            return gated
        }
        defer { fixture.close(); Task { await gate.release() } }
        for _ in 0..<300 {
            if await gate.hasPendingRead { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await gate.hasPendingRead)
        try fixture.refresh()
        if repeated { fixture.controller.performRefreshWorkspace() }
        try await Self.wait { fixture.node("src") != nil }
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.node("src") != nil)
    }
}
