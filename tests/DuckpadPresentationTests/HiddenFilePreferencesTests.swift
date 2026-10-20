import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
import Foundation
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct HiddenFilePreferencesTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test func settingsToggleUpdatesThePersistedValueAndFitsEveryLocale() async throws {
        _ = NSApplication.shared
        let panel = DuckpadSettingsWindowController()
        defer { panel.close() }
        var saved = AppSettings.defaults
        panel.configure(settings: saved) { saved = $0; return .saved($0) }
        let root = try #require(panel.window?.contentView)
        let toggle = try #require(views(root).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("Show hidden files") })
        #expect(toggle.state == .off)
        toggle.state = .on
        _ = NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        try await wait { saved.showHiddenFiles }
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            panel.refreshLocalization(catalog: catalog); root.layoutSubtreeIfNeeded()
            #expect(toggle.title == catalog.text("Show hidden files"))
            #expect(toggle.toolTip == catalog.text("Show hidden files in the workspace and file searches. Search ignore rules still apply."))
            #expect(toggle.frame.width + 1 >= toggle.intrinsicContentSize.width)
        }
    }
    private func result(_ title: String) -> MultiFileSearchResults {
        let tab = TabID()
        return .open(.init(generation: 0, documents: [.init(tabID: tab, title: title,
            matches: [.init(tabID: tab, bufferID: BufferID(), revision: 0, range: .init(location: 0, length: 6),
                line: 1, column: 1, snippet: title)])], isTruncated: false, searchedByteCount: 6))
    }
    @Test func changingVisibilityRejectsDelayedSearchResultsFromTheOldPreference() async throws {
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        var release = false, started = false, completed = 0
        defer { release = true; panel.dismiss() }
        panel.onSearch = { query, _ in
            if !query.options.includeHiddenFiles { started = true; while !release { await Task.yield() } }
            completed += 1
            return result(query.options.includeHiddenFiles ? "new" : "stale")
        }
        panel.setQuery(.init(pattern: "needle")); panel.searchPressed()
        try await wait { started }
        var settings = AppSettings.defaults; settings.showHiddenFiles = true
        panel.applyPreferences(settings)
        try await wait { panel.rows.first?.title == "new" }
        release = true; try await wait { completed == 2 }
        #expect(panel.rows.first?.title == "new")
    }
    @Test func changingVisibilityCancelsTheOldReplaceAllConfirmation() async throws {
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        var replacements = 0
        panel.onSearch = { _, _ in result("needle") }
        panel.onReplace = { _, _ in replacements += 1; return .init(documents: [], wasCancelled: false) }
        panel.setQuery(.init(pattern: "needle", replacement: "goose")); panel.searchPressed()
        let root = try #require(panel.window?.contentView)
        let button = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.apply" } as? NSButton)
        try await wait { button.isEnabled }
        panel.replacePressed(); #expect(panel.window?.attachedSheet != nil)
        var settings = AppSettings.defaults; settings.showHiddenFiles = true
        panel.applyPreferences(settings)
        try await wait { panel.window?.attachedSheet == nil }
        #expect(replacements == 0)
    }
    @Test func changingVisibilityRefreshesExpandedTreeAndAnAlreadyOpenFilenameSearch() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["visible.txt", ".secret"] { try Data("needle".utf8).write(to: folder.appendingPathComponent(name)) }
        defer { try? FileManager.default.removeItem(at: base) }
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json")))
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            folderFileNameIndex: LocalFolderFileNameIndex(executable: nil), workspaceBrowserUseCase: browser, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup(); _ = await browser.addRoot(folder)
        defer { controller.close() }
        if !controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
        let root = try #require(controller.window?.contentView)
        let outline = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.workspace.outline" } as? NSOutlineView)
        outline.expandItem(outline.item(atRow: 0))
        try await wait { outline.numberOfRows == 2 }
        controller.performSearchFiles()
        let files = controller.searchExperience.filePanel
        try await wait { files.results.contains { $0.name == "visible.txt" } }
        #expect(!files.results.contains { $0.name == ".secret" })
        var settings = AppSettings.defaults; settings.showHiddenFiles = true
        controller.applyPreferences(settings)
        try await wait { files.results.contains { $0.name == ".secret" } && outline.numberOfRows == 3 }
        #expect(outline.isItemExpanded(outline.item(atRow: 0)))
        #expect(controller.searchPanel.currentQuery().options.includeHiddenFiles)
        #expect(controller.searchExperience.multiPanel.currentQuery().options.includeHiddenFiles)
        settings.showHiddenFiles = false; controller.applyPreferences(settings)
        try await wait { files.results.contains { $0.name == "visible.txt" } && !files.results.contains { $0.name == ".secret" } && outline.numberOfRows == 2 }
        #expect(!controller.searchPanel.currentQuery().options.includeHiddenFiles)
        #expect(!controller.searchExperience.multiPanel.currentQuery().options.includeHiddenFiles)
    }
}
