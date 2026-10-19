import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct GeneratedTitleSearchAndCompareTests {
    @Test func capturedSearchAndComparisonTitlesFollowEveryCatalog() async throws {
        _ = NSApplication.shared
        var session = ScratchSession()
        let first = session.addUntitled(), second = session.addUntitled()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start(); binding.render(workspace.snapshot())
        defer { editor.invalidate() }
        for tab in workspace.snapshot().tabs {
            editor.install(.init(bufferID: tab.buffer.bufferID, revision: tab.buffer.revision, text: "needle"))
        }
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let result = try await search.findAll(.init(pattern: "needle", options: .init(scope: .allOpenDocuments)))
        #expect(result.documents.map(\.generatedTitle) == [.untitled(1), .untitled(2)])
        let comparison = try OpenDocumentComparisonUseCase(workspace: workspace, editor: editor).capture(leftTabID: first, rightTabID: second)
        #expect(comparison.left.generatedTitle == .untitled(1))
        #expect(comparison.right.generatedTitle == .untitled(2))
        let panel = SearchPanelView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        let diff = try AlignedLineDiff.build(left: comparison.left.text, right: comparison.right.text)
        let comparePanel = OpenDocumentComparePanel(content: .init(title: "", leftTitle: "", rightTitle: "", leftText: "needle", rightText: "needle", comparison: comparison), diff: diff)
        defer { comparePanel.close() }
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            panel.refreshLocalization(catalog: catalog)
            panel.present(result)
            let cell = try #require(panel.tableView(NSTableView(), viewFor: nil, row: 0) as? NSTableCellView)
            let title = catalog.text("new %1$@", arguments: ["1"])
            #expect(cell.textField?.stringValue.hasPrefix(title) == true)
            #expect(cell.accessibilityLabel()?.hasPrefix(title) == true)
            comparePanel.refreshLocalization(catalog: catalog)
            #expect(comparePanel.window?.title == catalog.text("Diff — %1$@ ↔ %2$@", arguments: [title, catalog.text("new %1$@", arguments: ["2"])]))
        }
    }
}
