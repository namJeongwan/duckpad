import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

private actor DeferredFileSearchStore: WorkspaceRootStore {
    let root: WorkspaceRoot
    let read: WorkspaceFileRead
    let immediateRead: WorkspaceFileRead
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    init(root: WorkspaceRoot, read: WorkspaceFileRead, immediateRead: WorkspaceFileRead) { self.root = root; self.read = read; self.immediateRead = immediateRead }
    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] { [root] }
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { root }
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) { }
    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] { [] }
    func updateNavigation(rootID: WorkspaceRootID, expandedRelativePaths: [String], selectedRelativePath: String?) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { root }
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        if entry.name != "b.txt" { return immediateRead }
        requested = true
        await withCheckedContinuation { waiter = $0 }
        return read
    }
    func finish() { waiter?.resume(); waiter = nil }
}

@Suite(.serialized) @MainActor
struct FileSearchSplitRoutingTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func pressSplit(_ panel: FileNameSearchController) throws {
        let root = try #require(panel.window?.contentView)
        let button = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.files.split" } as? NSButton)
        _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button)
    }
    @Test func rightSplitOpensInactiveAndUnopenedFilesWithoutReplacingTheInvokingPane() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt")
        for url in [a, b, c] { try Data(url.lastPathComponent.utf8).write(to: url) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: root.appendingPathComponent(".roots.json")))
        _ = await browser.start(); _ = await browser.addRoot(root)
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, secondaryEditorView: editor.secondaryGroupView, editorGroupRouter: editor, fileUseCase: files, workspaceBrowserUseCase: browser, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        _ = await files.open(b); _ = await files.open(a)
        let aID = try #require(workspace.snapshot().tabs.first { $0.fullPath == a.path }?.id)
        let bID = try #require(workspace.snapshot().tabs.first { $0.fullPath == b.path }?.id)
        controller.performSearchFiles(); controller.searchExperience.filePanel.setQuery("b.txt")
        try pressSplit(controller.searchExperience.filePanel)
        for _ in 0..<100 where controller.editorGroupLayoutSnapshot.visibleGroups.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        var layout = controller.editorGroupLayoutSnapshot
        #expect(layout.primarySelectedTabID == aID); #expect(layout.selectedTabID(in: layout.focusedGroup) == bID)
        let invokingGroup = layout.focusedGroup
        controller.performSearchFiles()
        let panel = controller.searchExperience.filePanel
        panel.setQuery("c.txt")
        for _ in 0..<100 where panel.results.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results.map(\.name) == ["c.txt"])
        try pressSplit(panel)
        for _ in 0..<100 where controller.editorGroupLayoutSnapshot.visibleGroups.count != 3 { try await Task.sleep(for: .milliseconds(5)) }
        layout = controller.editorGroupLayoutSnapshot
        let cID = try #require(workspace.snapshot().tabs.first { $0.fullPath == c.path }?.id)
        #expect(layout.primarySelectedTabID == aID); #expect(layout.selectedTabID(in: invokingGroup) == bID)
        #expect(layout.selectedTabID(in: layout.focusedGroup) == cID)
        // A result already visible elsewhere must still open beside the invoking pane.
        let third = layout.focusedGroup
        controller.performSearchFiles(); panel.setQuery("a.txt"); try pressSplit(panel)
        for _ in 0..<100 where controller.editorGroupLayoutSnapshot.visibleGroups.count != 4 { try await Task.sleep(for: .milliseconds(5)) }
        layout = controller.editorGroupLayoutSnapshot
        #expect(layout.visibleGroups.count == 4); #expect(layout.selectedTabID(in: third) == cID)
        #expect(layout.selectedTabID(in: layout.focusedGroup) == aID)
        for url in [a, b, c] { #expect(try String(contentsOf: url, encoding: .utf8) == url.lastPathComponent) }
        await files.releaseAllSecurityScopedAccess()
    }
    @Test(arguments: [false, true]) func newerFileOpenCancelsAnOlderDeferredRequestInBothDirections(splitFirst: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("b.txt"); try Data("keep me".utf8).write(to: url)
        let cURL = root.appendingPathComponent("c.txt"); try Data("newest file".utf8).write(to: cURL)
        let fileStore = LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json"))
        let rootInfo = WorkspaceRoot(canonicalPath: root.path, displayName: "Test")
        let store = DeferredFileSearchStore(root: rootInfo, read: .init(url: url, result: try await fileStore.read(from: url)), immediateRead: .init(url: cURL, result: try await fileStore.read(from: cURL)))
        let browser = WorkspaceBrowserUseCase(store: store); _ = await browser.start()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
        var splitIDs: [TabID] = [], normalNames: [String] = []
        let coordinator = SearchExperienceCoordinator(workspace: workspace, search: nil, folderSearch: nil, files: files, browser: browser, parent: nil, actionable: { true }, openWorkspace: { normalNames.append($0.name) }, activate: { _ in }, onGesture: {}, chooseFolder: { _ in nil })
        defer { coordinator.tearDown(); editor.invalidate() }
        coordinator.prepareFileSplit = { { splitIDs.append($0) } }
        let b = WorkspaceBrowserEntry(rootID: rootInfo.id, relativePath: "b.txt", name: "b.txt", kind: .file)
        let c = WorkspaceBrowserEntry(rootID: rootInfo.id, relativePath: "c.txt", name: "c.txt", kind: .file)
        let older = FileNameSearchEntry(name: b.name, path: url.path, target: .workspace(b))
        if splitFirst { coordinator.filePanel.onOpenInSplit?(older) } else { coordinator.filePanel.onOpen?(older) }
        for _ in 0..<100 { if await store.requested { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await store.requested)
        let newer = FileNameSearchEntry(name: c.name, path: cURL.path, target: .workspace(c))
        if splitFirst { coordinator.filePanel.onOpen?(newer) } else { coordinator.filePanel.onOpenInSplit?(newer) }
        for _ in 0..<100 where workspace.snapshot().tabs.allSatisfy({ $0.fullPath != cURL.path }) { try await Task.sleep(for: .milliseconds(5)) }
        await store.finish(); try await Task.sleep(for: .milliseconds(60))
        #expect(normalNames.isEmpty)
        let newestID = try #require(workspace.snapshot().tabs.first { $0.fullPath == cURL.path }?.id)
        #expect(splitIDs == (splitFirst ? [] : [newestID]))
        #expect(!workspace.snapshot().tabs.contains { $0.fullPath == url.path })
        await files.releaseAllSecurityScopedAccess()
    }
}
