import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct SearchDialogInteractionTests {
    @Test func incrementalFindDoesNotExpandTheResultsList() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: adapter,
                                                editorView: adapter.view, searchUseCase: search,
                                                automaticallyStarts: false)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: descriptor.bufferID, revision: descriptor.revision, text: "return one\nreturn two"))
        adapter.display(descriptor)
        controller.performShowFind()
        let panel = controller.searchPanel
        panel.show(replace: false, selectedText: "return")
        let before = try #require(panel.window).frame
        panel.onIncrementalQuery?(panel.currentQuery())
        for _ in 0..<100 {
            if panel.numberOfRows(in: NSTableView()) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.numberOfRows(in: NSTableView()) == 3)
        #expect(panel.window?.frame == before)
        #expect(panel.frame.height <= 330)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try #require(descendants(panel).compactMap { $0 as? NSTableView }.first)
        #expect(table.isHiddenOrHasHiddenAncestor)
        let cancel = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.cancel" })
        #expect(cancel.isHiddenOrHasHiddenAncestor)
        panel.show(replace: false) // Queue a refresh immediately before an explicit command.
        panel.onFindAll?(panel.currentQuery())
        for _ in 0..<100 {
            if !table.isHiddenOrHasHiddenAncestor { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!table.isHiddenOrHasHiddenAncestor)
        let backwards = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.backwards" } as? NSButton)
        backwards.performClick(nil)
        controller.performFindNext()
        for _ in 0..<100 {
            if adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6))
    }
    @Test func replaceAllOpenDocumentsRoutesWithoutAnIncrementalRefreshOverwritingItsSummary() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: adapter,
            editorView: adapter.view, searchUseCase: search, automaticallyStarts: false)
        defer { controller.close() }
        controller.start(); await controller.waitForStartup()
        let first = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: first.bufferID, revision: first.revision, text: "duck duck"))
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: second.bufferID, revision: second.revision, text: "duck"))
        controller.performShowReplace()
        let panel = controller.searchPanel
        panel.show(replace: true, selectedText: "duck")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let replacement = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace" } as? NSTextField)
        replacement.stringValue = "goose"
        let scope = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace-scope" } as? NSPopUpButton)
        scope.selectItem(at: 2); scope.sendAction(scope.action, to: scope.target)
        let button = try #require(descendants(panel).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("replaceAllPressed") })
        button.sendAction(button.action, to: button.target)
        for _ in 0..<100 {
            if adapter.snapshot(for: second.bufferID)?.text == "goose" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(adapter.snapshot(for: first.bufferID)?.text == "goose goose")
        #expect(adapter.snapshot(for: second.bufferID)?.text == "goose")
        #expect(workspace.snapshot().activeBuffer?.bufferID == second.bufferID)
        #expect(panel.numberOfRows(in: NSTableView()) == 2)
        let status = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.status" } as? NSTextField)
        #expect(status.stringValue.contains("3"))
    }

    @Test func cancellingANewPlanDoesNotReuseThePreviousReplacementCount() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let engine = SearchScanBarrierRegexEngine(base: ICURegexEngine())
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: engine)
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: adapter,
            editorView: adapter.view, searchUseCase: search, automaticallyStarts: false)
        defer { controller.close() }
        controller.start(); await controller.waitForStartup()
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: "duck"))
        controller.performShowReplace()
        let panel = controller.searchPanel
        panel.show(replace: true, selectedText: "duck")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scope = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace-scope" } as? NSPopUpButton)
        scope.selectItem(at: 2); scope.sendAction(scope.action, to: scope.target)
        var blockedQuery = panel.currentQuery(); blockedQuery.options.mode = .regularExpression
        panel.setQuery(blockedQuery)
        panel.present(OpenDocumentsReplacementResult(documents: [.init(tabID: TabID(), title: "old.txt", status: .replaced(99))], wasCancelled: false))
        let replace = try #require(descendants(panel).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("replaceAllPressed") })
        replace.sendAction(replace.action, to: replace.target)
        await engine.waitUntilScanEntered()
        let cancel = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.cancel" } as? NSButton)
        cancel.sendAction(cancel.action, to: cancel.target)
        engine.releaseScan()
        try await Task.sleep(for: .milliseconds(250))
        let status = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.status" } as? NSTextField)
        #expect(!status.stringValue.contains("99"))
        #expect(panel.numberOfRows(in: NSTableView()) == 0)
        #expect(adapter.snapshot(for: buffer.bufferID)?.text == "duck")
    }

}
