import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchScopeAndDesignTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test func fourScopeControlsKeepTheFolderSeparateAndDisableAbsentWorkspace() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); defer { panel.dismiss() }
        panel.present(replace: true, in: nil)
        let root = try #require(panel.window?.contentView)
        let scopes = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.scope" } as? NSSegmentedControl)
        #expect(scopes.segmentCount == 4); #expect(!scopes.isEnabled(forSegment: 2))
        panel.selectScope(.workspace); #expect(panel.selectedScope == .all)
        panel.configureWorkspace([.init(canonicalPath: "/project", displayName: "project")])
        var requests: [(ProjectSearchScope, URL?)] = []
        panel.onSearchRequest = { _, scope, folder, _ in
            requests.append((scope, folder))
            return .open(.init(generation: 0, documents: [], isTruncated: false, searchedByteCount: 0))
        }
        panel.setQuery(.init(pattern: "needle"))
        for (index, scope) in [ProjectSearchScope.workspace, .folder, .all, .openDocuments].enumerated() {
            if scope == .folder { panel.selectFolder(URL(fileURLWithPath: "/external")) } else { panel.selectScope(scope) }
            panel.searchPressed()
            try await wait { requests.count == index + 1 }
            #expect(requests[index].0 == scope)
            #expect(requests[index].1?.path == (scope == .folder ? "/external" : nil))
            let directory = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.directory" })
            #expect(directory.toolTip == (scope == .folder ? "/external" : scope == .openDocuments ? nil : "/project"))
        }
        for language in AppLanguage.allCases where language != .system {
            panel.refreshLocalization(catalog: .init(language: language)); panel.window?.setContentSize(.init(width: 720, height: 460))
            root.layoutSubtreeIfNeeded()
            let rect = scopes.convert(scopes.bounds, to: root)
            #expect(rect.minX >= 0 && rect.maxX <= root.bounds.width)
        }
    }
    @Test func findKeepsLabeledFieldsNativeOptionsAndCompactActionsInEveryLocale() throws {
        _ = NSApplication.shared
        let panel = SearchPanelView(frame: .zero), controller = SearchWindowController(searchView: panel)
        defer { controller.dismiss() }
        panel.show(replace: true); panel.setQuery(.init(pattern: "한글 needle", replacement: "오리"))
        controller.present(in: nil)
        let window = try #require(controller.window)
        for language in AppLanguage.allCases where language != .system {
            panel.refreshLocalization(catalog: .init(language: language))
            window.contentView?.layoutSubtreeIfNeeded()
            for (suffix, key) in [("find", "Find"), ("replace", "Replace with")] {
                let field = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search." + suffix } as? NSTextField)
                let label = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search.label." + key } as? NSTextField)
                #expect(label.stringValue == LocalizationCatalog(language: language).text(key))
                #expect(label.convert(label.bounds, to: panel).maxX < field.convert(field.bounds, to: panel).minX)
                #expect(field.isBezeled)
            }
            let toggle = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search.match-case" } as? NSButton)
            #expect(!(toggle is SearchOptionButton))
            #expect(toggle.title == LocalizationCatalog(language: language).text("Match case"))
            toggle.performClick(nil); #expect(panel.currentQuery().options.matchCase)
            toggle.performClick(nil); #expect(!panel.currentQuery().options.matchCase)
            let modes = views(panel).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("duckpad.search.mode.") }
            #expect(modes.count == 3); #expect(modes.allSatisfy { !($0 is SearchOptionButton) })
            let actions = views(panel).compactMap { $0 as? SearchActionButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(!actions.isEmpty)
            for action in actions { #expect(action.bounds.height == 24); #expect(action.bounds.width + 1 >= action.intrinsicContentSize.width) }
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SNAPSHOTS"] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance); window.displayIfNeeded()
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory + "/unified-find-" + language.rawValue + "-" + appearance.rawValue + ".png"]
                    try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
                }
            }
        }
    }
    @Test(arguments: [false, true]) func leavingProjectScopeRemovesItsMenuItemAndCannotReactivateAnUnboundScope(replacing: Bool) throws {
        _ = NSApplication.shared
        let panel = SearchPanelView(frame: .zero); defer { panel.hide() }
        panel.refreshLocalization(catalog: .init(language: .english))
        panel.show(replace: replacing); panel.setQuery(.init(pattern: "needle"))
        panel.present(ProjectSearchResult(open: .init(generation: 0, documents: [], isTruncated: false, searchedByteCount: 0),
            folder: .init(rootPath: "/project", documents: [], isTruncated: false, searchedFileCount: 0, skippedFileCount: 0, searchedByteCount: 0),
            context: .init(scope: .workspace, roots: [], folder: nil)))
        let scope = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace-scope" } as? NSPopUpButton)
        #expect(scope.numberOfItems == 4); #expect(scope.indexOfSelectedItem == 3)
        scope.selectItem(at: 0); _ = NSApp.sendAction(try #require(scope.action), to: scope.target, from: scope)
        #expect(scope.numberOfItems == 3)
        #expect(panel.currentQuery().options.scope == .document)
        scope.selectItem(at: 2); _ = NSApp.sendAction(try #require(scope.action), to: scope.target, from: scope)
        #expect(panel.currentQuery().options.scope == .allOpenDocuments)
        if !replacing {
            let findAll = try #require(views(panel).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("findAllPressed") })
            #expect(findAll.title == "Find All")
            let selection = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search.selection" })
            #expect(selection.isHiddenOrHasHiddenAncestor)
        }
    }
    @Test func folderResultsKeepTheirScopeWhenClassicFindReplaces() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = selected.appendingPathComponent("inside.txt"), outside = root.appendingPathComponent("outside.txt")
        for path in [inside, outside] { try Data("needle".utf8).write(to: path) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let disk = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            fileUseCase: files, searchUseCase: search, folderSearchUseCase: disk, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup(); _ = await files.open(outside)
        defer { controller.close(); editor.invalidate() }
        _ = controller.searchExperience
        let outsideTab = try #require(workspace.snapshot().tabs.first { $0.fullPath == outside.path })
        let query = SearchQuery(pattern: "needle", replacement: "goose")
        let preview = try await ProjectSearchUseCase(workspace: workspace, search: search, folderSearch: disk).find(query, scope: .folder, roots: [], folder: selected)
        controller.searchPanel.show(replace: true); controller.searchPanel.setQuery(query); controller.searchPanel.present(preview)
        let button = try #require(views(controller.searchPanel).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("replaceAllPressed") })
        button.performClick(nil)
        try await wait { workspace.snapshot().tabs.contains { $0.fullPath == inside.path && $0.isDirty } }
        #expect(editor.snapshot(for: outsideTab.buffer.bufferID)?.text == "needle")
        #expect(try String(contentsOf: inside, encoding: .utf8) == "needle")
        let insideTab = try #require(workspace.snapshot().tabs.first { $0.fullPath == inside.path })
        _ = await workspace.activate(tabID: insideTab.id); editor.activeScintillaView?.undo()
        #expect(editor.snapshot(for: insideTab.buffer.bufferID)?.text == "needle")
        await files.releaseAllSecurityScopedAccess()
    }
}
