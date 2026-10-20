import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct FileNameSearchScopeTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test func fourScopesKeepOpenTargetsAndDoNotMixTheChosenFolderIntoAll() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); defer { panel.dismiss() }
        let openID = TabID(), scratchID = TabID()
        let opened = FileNameSearchEntry(name: "open.txt", path: "/project/open.txt", target: .tab(openID))
        let external = FileNameSearchEntry(name: "outside.txt", path: "/outside.txt", target: .tab(TabID()))
        let scratch = FileNameSearchEntry(name: "new 1", path: "new 1", target: .tab(scratchID))
        let root = WorkspaceRoot(canonicalPath: "/project", displayName: "project")
        let disk = FileNameSearchEntry(name: "disk.txt", path: "/project/disk.txt", target: .workspace(.init(rootID: root.id, relativePath: "disk.txt", name: "disk.txt", kind: .file)))
        var requests: [(ProjectSearchScope, URL?)] = []
        panel.onLoadRequest = { scope, folder in
            requests.append((scope, folder))
            return (scope == .folder ? [.init(name: "chosen.txt", path: "/chosen/chosen.txt", target: .folder(root: URL(fileURLWithPath: "/chosen"), authority: .init(canonicalPath: "/chosen", device: 0, inode: 0), relativePath: "chosen.txt"))] : [opened, disk], false, 0)
        }
        panel.configureWorkspace([root]); panel.present(in: nil, initial: [opened, external, scratch])
        try await wait { panel.results.count == 4 }
        #expect(requests.last?.0 == .all); #expect(requests.last?.1 == nil)
        panel.selectScope(.openDocuments)
        #expect(panel.results.map(\.path) == [opened.path, external.path, scratch.path])
        let count = requests.count; await Task.yield(); #expect(requests.count == count)
        panel.selectScope(.workspace); try await wait { panel.results.count == 2 }
        #expect(Set(panel.results.map(\.path)) == [opened.path, disk.path])
        if case .tab(let id) = panel.results.first(where: { $0.path == opened.path })?.target { #expect(id == openID) }
        else { Issue.record("Workspace result lost its already-open tab") }
        panel.setQuery("chosen"); panel.selectFolder(URL(fileURLWithPath: "/chosen"))
        try await wait { panel.results.first?.name == "chosen.txt" }
        #expect(requests.last?.0 == .folder); #expect(requests.last?.1?.path == "/chosen")
        panel.selectScope(.all); try await wait { requests.last?.0 == .all }
        #expect(panel.results.isEmpty) // query remains 'chosen'; selected folder is excluded from All.
        panel.setQuery(""); try await wait { panel.results.count == 4 }
        #expect(!panel.results.contains { $0.path.hasPrefix("/chosen/") })
        panel.configureWorkspace([]); panel.selectScope(.workspace); #expect(panel.selectedScope == .all)
    }
    @Test func changingScopeAndDismissalRejectLateIndexAndFolderPickerResults() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); defer { panel.dismiss() }
        var release = false, entered = false
        panel.onLoadRequest = { _, _ in
            entered = true
            while !release { await Task.yield() }
            return ([.init(name: "stale.txt", path: "/stale.txt", target: .tab(TabID()))], false, 0)
        }
        panel.present(in: nil, initial: [.init(name: "new 1", path: "new 1", target: .tab(TabID()))])
        try await wait { entered }
        panel.selectScope(.openDocuments); release = true
        for _ in 0..<10 { await Task.yield() }
        #expect(panel.results.map(\.name) == ["new 1"])
        panel.selectScope(.folder)
        let root = try #require(panel.window?.contentView)
        let browse = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.files.browse" } as? NSButton)
        var pickerRelease = false, pickerEntered = false
        panel.onChooseFolder = { pickerEntered = true; while !pickerRelease { await Task.yield() }; return URL(fileURLWithPath: "/late") }
        _ = NSApp.sendAction(try #require(browse.action), to: browse.target, from: browse)
        try await wait { pickerEntered }
        panel.dismiss(); pickerRelease = true
        for _ in 0..<10 { await Task.yield() }
        #expect(panel.folder == nil); #expect(panel.window?.isVisible == false)
    }
    @Test func coordinatorSearchesEveryRootAndFolderOpensBesideTheInvokingDocument() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), chosen = root.appendingPathComponent("chosen")
        for dir in [a, b, chosen] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = a.appendingPathComponent("open.txt"), second = b.appendingPathComponent("disk.txt"), outside = root.appendingPathComponent("outside.txt"), selected = chosen.appendingPathComponent("selected.txt")
        for url in [first, second, outside, selected] { try Data("keep me".utf8).write(to: url) }
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: root.appendingPathComponent(".roots.json")))
        _ = await browser.start(); _ = await browser.addRoot(a); _ = await browser.addRoot(b)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        _ = await workspace.start()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        _ = await files.open(first); _ = await files.open(outside)
        let invoking = try #require(workspace.snapshot().tabs.first(where: \.isActive)?.id)
        var splitTarget: TabID?
        let coordinator = SearchExperienceCoordinator(workspace: workspace, search: nil, folderSearch: nil, folderFileNames: LocalFolderFileNameIndex(executable: nil), files: files, browser: browser, parent: nil, actionable: { true }, openWorkspace: { _ in }, activate: { _ in }, onGesture: {}, chooseFolder: { _ in chosen })
        coordinator.prepareFileSplit = { { splitTarget = $0 } }
        defer { coordinator.tearDown(); editor.invalidate() }
        coordinator.showFiles()
        let panel = coordinator.filePanel
        try await wait { panel.results.contains { $0.path == second.path } }
        #expect(panel.results.contains { $0.path == outside.path }); #expect(!panel.results.contains { $0.path == selected.path })
        panel.selectScope(.workspace)
        try await wait { Set(panel.results.map(\.path)) == [first.path, second.path] }
        panel.selectScope(.openDocuments)
        #expect(panel.results.contains { $0.path == outside.path }); #expect(!panel.results.contains { $0.path == second.path })
        panel.selectFolder(chosen)
        try await wait { panel.results.map(\.path) == [selected.path] }
        #expect(browser.roots.count == 2)
        let entry = try #require(panel.results.first)
        panel.onOpenInSplit?(entry)
        try await wait { splitTarget != nil }
        #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == invoking)
        #expect(workspace.snapshot().tabs.first { $0.id == splitTarget }?.fullPath == selected.path)
        panel.onOpen?(entry)
        try await wait { workspace.snapshot().tabs.first(where: \.isActive)?.id == splitTarget }
        #expect(try String(contentsOf: selected, encoding: .utf8) == "keep me")
        await files.releaseAllSecurityScopedAccess()
    }
    @Test func preparedFolderNavigationKeepsBinaryLikeBytesWhenProjectCharsetIsPresent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("root=true\n[*]\ncharset=utf-16le\n".utf8).write(to: root.appendingPathComponent(".editorconfig"))
        let url = root.appendingPathComponent("safe.txt")
        try TextFileCodec.encode("safe", encoding: .utf16LittleEndian, byteOrderMark: .absent).write(to: url)
        let indexer = LocalFolderFileNameIndex(executable: nil), index = try await indexer.index(in: root)
        let read = try await indexer.readFile(in: root, root: index.root, relativePath: "safe.txt")
        #expect(BinaryFileContent.isBinary(read.result.data))
        // Any subsequent path read would fail. Navigation must decode its verified snapshot.
        try FileManager.default.removeItem(at: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        _ = await workspace.start(); defer { editor.invalidate() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        files.conventionsUseCase = DocumentConventionsUseCase(reader: LocalEditorConfigReader(), workspace: workspace, editor: editor)
        let initial = workspace.snapshot().tabs.first(where: \.isActive)?.id
        guard case .opened(let id) = await files.prepareFileForNavigation(read) else { Issue.record("safe prepared bytes were read again by path"); return }
        #expect(workspace.snapshot().tabs.first(where: \.isActive)?.id == initial)
        let tab = try #require(workspace.snapshot().tabs.first { $0.id == id })
        #expect(editor.snapshot(for: tab.buffer.bufferID)?.text == "safe")
        #expect(workspace.fileContext(tabID: id)?.binding?.observedIdentity == read.result.identity)
        await files.releaseAllSecurityScopedAccess()
    }

    @Test(arguments: [false, true])
    func changedFolderLinksCannotOpenOrActivateOutsideFiles(inSplit: Bool) async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = selected.appendingPathComponent("safe.txt")
        try Data("safe".utf8).write(to: target); try Data("outside".utf8).write(to: outside)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        _ = await workspace.start(); defer { editor.invalidate() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: base.appendingPathComponent(".access.json")))
        _ = await files.open(outside); _ = await workspace.addScratch()
        let before = workspace.snapshot().tabs
        var split = false
        let coordinator = SearchExperienceCoordinator(workspace: workspace, search: nil, folderSearch: nil, folderFileNames: LocalFolderFileNameIndex(executable: nil), files: files, browser: nil, parent: nil, actionable: { true }, openWorkspace: { _ in }, activate: { _ in }, onGesture: {}, chooseFolder: { _ in selected })
        coordinator.prepareFileSplit = { { _ in split = true } }
        defer { coordinator.tearDown() }
        let panel = coordinator.filePanel
        let load = try #require(panel.onLoadRequest)
        let result = try await load(.folder, selected)
        let entry = try #require(result.entries.first)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        if inSplit { panel.onOpenInSplit?(entry) } else { panel.onOpen?(entry) }
        await coordinator.waitForFileOpen()
        #expect(!split); #expect(workspace.snapshot().tabs == before)
        await files.releaseAllSecurityScopedAccess()
    }

}
