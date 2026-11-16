import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchQueryStabilityTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Search did not settle")
    }
    private func result(_ text: String, tab: TabID, buffer: BufferID, incomplete: Bool = false) -> MultiFileSearchResults {
        .open(.init(generation: 1, documents: [.init(tabID: tab, title: "config.py", matches: [
            .init(tabID: tab, bufferID: buffer, revision: 0, range: .init(location: 0, length: 4), line: 1, column: 1, snippet: text)
        ])], isTruncated: incomplete, searchedByteCount: text.utf8.count))
    }

    @Test func replacementShortcutAutomaticallyFindsHongyoungWithoutPressingSearch() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            searchUseCase: search, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        let native = try #require(editor.activeScintillaView)
        native.insertCommittedText("host = \"https://dp-stats.hongyoungjun.com\"\n")
        let before = workspace.snapshot().tabs
        controller.performReplaceInFiles()
        let panel = controller.searchExperience.multiPanel
        let panelContent = try #require(panel.window?.contentView)
        let field = try #require(views(panelContent).first {
            $0.accessibilityIdentifier() == "duckpad.multifile.find"
        } as? NSTextField)
        field.stringValue = "hongyoung"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
        try await wait { panel.result?.matchCount == 1 }
        #expect(panel.rows.first?.title.contains("hongyoungjun.com") == true)
        #expect(workspace.snapshot().tabs == before)
        #expect(native.contentUTF8 == Data("host = \"https://dp-stats.hongyoungjun.com\"\n".utf8))
    }

    @Test func typingKeepsRowsAndPreviewUntilFreshResultsAndBlocksStaleActions() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController()
        let tab = TabID(), buffer = BufferID()
        let previous = result("hongyoung previous", tab: tab, buffer: buffer)
        let fresh = result("hongyoung current", tab: tab, buffer: buffer)
        var started = false, release = false, activated = false
        var progress: MultiFileSearchController.Progress?
        panel.onSearchWithProgress = { query, _, receive in
            if query.pattern == "hong" { return previous }
            started = true; progress = receive
            while !release { await Task.yield() }
            return fresh
        }
        panel.onActivate = { _ in activated = true }
        panel.present(replace: true, in: nil)
        defer { release = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "hong"))
        try await wait { panel.result != nil }
        let content = try #require(panel.window?.contentView)
        let preview = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.multifile.preview" } as? NSTextView)
        let visiblePreview = preview.string
        try #require(!visiblePreview.isEmpty)
        panel.setQuery(.init(pattern: "hongyoung"))
        #expect(panel.rows.first?.title == "hongyoung previous")
        #expect(preview.string == visiblePreview)
        try await wait { started }
        progress?(.open(.init(generation: 2, documents: [], isTruncated: true, searchedByteCount: 0)))
        #expect(panel.rows.first?.title == "hongyoung previous")
        #expect(preview.string == visiblePreview)
        for identifier in ["duckpad.multifile.apply", "duckpad.multifile.replaceOne", "duckpad.multifile.openResults"] {
            let button = try #require(views(content).first { $0.accessibilityIdentifier() == identifier } as? NSButton)
            #expect(!button.isEnabled)
        }
        panel.activateSelection()
        #expect(!activated)
        release = true
        try await wait { panel.rows.first?.title == "hongyoung current" }
        #expect(preview.string.contains("hongyoung current"))
        panel.setQuery(.init(pattern: ""))
        #expect(panel.rows.isEmpty)
        #expect(preview.string.isEmpty)
    }

    @Test func completedZeroMatchesClearsPreviouslyDisplayedResults() async throws {
        let panel = MultiFileSearchController()
        let previous = result("hongyoung", tab: TabID(), buffer: BufferID())
        panel.onSearch = { query, _ in
            query.pattern == "hong" ? previous : .open(.init(generation: 2, documents: [], isTruncated: false, searchedByteCount: 0))
        }
        panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        panel.setQuery(.init(pattern: "hong"))
        try await wait { panel.result?.matchCount == 1 }
        panel.setQuery(.init(pattern: "absent"))
        try await wait { panel.result?.matchCount == 0 }
        #expect(panel.rows.isEmpty)
    }

    @Test func identicalAndAppendingProgressPreservesPreviewTextSelection() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(), tab = TabID(), buffer = BufferID()
        var progress: MultiFileSearchController.Progress?, release = false
        func snapshot(_ count: Int) -> MultiFileSearchResults {
            .open(.init(generation: 1, documents: [.init(tabID: tab, title: "config.py", matches: (0..<count).map {
                .init(tabID: tab, bufferID: buffer, revision: 0, range: .init(location: $0 * 20, length: 4),
                    line: $0 + 1, column: 1, snippet: "hongyoung line \($0)")
            })], isTruncated: true, searchedByteCount: count * 20))
        }
        panel.onSearchWithProgress = { _, _, receive in
            progress = receive
            while !release { await Task.yield() }
            return snapshot(2)
        }
        panel.present(replace: false, in: nil)
        defer { release = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "hong"))
        try await wait { progress != nil }
        progress?(snapshot(1))
        let content = try #require(panel.window?.contentView)
        let preview = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.multifile.preview" } as? NSTextView)
        let table = try #require(views(content).compactMap { $0 as? NSTableView }.first)
        let selection = NSRange(location: 2, length: 3)
        preview.setSelectedRange(selection)
        progress?(snapshot(1))
        #expect(preview.selectedRange() == selection)
        progress?(snapshot(2))
        #expect(table.numberOfRows == 2)
        #expect(table.selectedRow == 0)
        #expect(preview.selectedRange() == selection)
    }

    @Test func searchFailureCannotBeRepopulatedByALatePreview() async throws {
        let panel = MultiFileSearchController()
        var failSearch = false, releasePreview = false, previewStarted = false, previewFinished = false
        let partial = result("hongyoung partial", tab: TabID(), buffer: BufferID(), incomplete: true)
        panel.onSearchWithProgress = { _, _, receive in
            receive(partial)
            while !failSearch { await Task.yield() }
            throw SearchFailure.invalidLimits
        }
        panel.onPreview = { _ in
            previewStarted = true
            while !releasePreview { await Task.yield() }
            previewFinished = true
            return .init(text: "late preview", firstLine: 1, matchLine: 1, highlight: .init(location: 0, length: 4))
        }
        panel.present(replace: false, in: nil)
        defer { failSearch = true; releasePreview = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "hongyoung"))
        try await wait { previewStarted }
        let content = try #require(panel.window?.contentView)
        let preview = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.multifile.preview" } as? NSTextView)
        failSearch = true
        try await wait { panel.result == nil && panel.rows.isEmpty }
        releasePreview = true
        try await wait { previewFinished }
        try await Task.sleep(for: .milliseconds(30))
        #expect(preview.string.isEmpty)
        #expect(panel.rows.isEmpty)
    }
}
