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
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: adapter,
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
        backwards.state = .on
        backwards.sendAction(backwards.action, to: backwards.target)
        controller.performFindNext()
        for _ in 0..<100 {
            if adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.activeSelectionUTF8Range() == .init(location: 0, length: 6))
    }
}
