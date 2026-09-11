import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite @MainActor
struct PanelLanguageRefreshTests {
    private let english = LocalizationCatalog(language: .english)
    private let korean = LocalizationCatalog(language: .korean)

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func field(_ identifier: String, in view: NSView) throws -> NSTextField {
        try #require(descendants(view).first { $0.accessibilityIdentifier() == identifier } as? NSTextField)
    }

    @Test func aboutRefreshRetainsWindowAndUpdateState() throws {
        let target = DuckpadAppInfoController(appInfo: .init(version: "0.3.0", build: "7"), loadRelease: { nil })
        let panel = DuckpadAboutWindowController(target: target)
        defer { panel.close() }
        panel.refreshLocalization(catalog: english)
        panel.render(.checking)
        let window = try #require(panel.window)
        let content = try #require(window.contentView)
        panel.refreshLocalization(catalog: korean)
        #expect(panel.window === window)
        #expect(window.contentView === content)
        #expect(window.title == korean.text("About Duckpad"))
        #expect(panel.updateTitle.stringValue == korean.text("Checking for updates…"))
        #expect(!panel.updateButton.isEnabled)
        #expect(try field("duckpad.about.version", in: content).stringValue == korean.text("Version %1$@", arguments: ["0.3.0"]) + " (7)")
        let copy = try #require(descendants(content).first { $0.accessibilityIdentifier() == "duckpad.about.copy-info" })
        #expect(copy.accessibilityLabel() == korean.text("Copy app info"))
        panel.render(.failed)
        #expect(panel.updateButton.title == korean.text("Try Again"))
        panel.refreshLocalization(catalog: english)
        #expect(panel.updateButton.title == "Try Again")
    }

    @Test func searchRefreshPreservesQueryOptionsResultsAndStatusSource() throws {
        let panel = SearchPanelView(frame: .zero)
        panel.refreshLocalization(catalog: english)
        panel.show(replace: true, selectedText: "File")
        let replacement = try field("duckpad.search.replace", in: panel)
        replacement.stringValue = "Save"
        let tabID = TabID()
        let match = SearchMatch(tabID: tabID, bufferID: BufferID(), revision: 7,
                                range: .init(location: 0, length: 4), line: 2, column: 1, snippet: "File")
        panel.present(SearchResultSet(generation: 5, documents: [.init(tabID: tabID, title: "File", matches: [match])],
                                      isTruncated: false, searchedByteCount: 4))
        let table = try #require(descendants(panel).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let query = panel.currentQuery()
        panel.refreshLocalization(catalog: korean)
        #expect(panel.currentQuery() == query)
        #expect(replacement.stringValue == "Save")
        #expect(replacement.placeholderString == korean.text("Replace with"))
        #expect(table.selectedRow == 1)
        #expect(table.numberOfRows == 2)
        #expect(table.tableColumns[0].title == korean.text("Search Results"))
        let header = try #require(panel.tableView(table, viewFor: nil, row: 0) as? NSTextField)
        #expect(header.stringValue == korean.text("%1$@ — %2$@", arguments: ["File", korean.text("search.matches", arguments: [1])]))
        let snippet = try #require(panel.tableView(table, viewFor: nil, row: 1) as? NSTextField)
        #expect(snippet.stringValue == "  2:1  File")
        panel.presentStatus(key: "Searching %1$@…", arguments: ["File"])
        panel.refreshLocalization(catalog: english)
        #expect(try field("duckpad.search.status", in: panel).stringValue == "Searching File…")
        panel.presentFailure(prefix: "Search failed: %1$@", error: SearchFailure.emptyPattern)
        panel.refreshLocalization(catalog: korean)
        #expect(try field("duckpad.search.status", in: panel).stringValue == korean.text("Search failed: %1$@", arguments: [korean.text("Enter text to search.")]))
    }

    @Test func comparisonRefreshPreservesSnapshotAndSelection() throws {
        let content = OpenDocumentCompareContent(title: "Diff — File ↔ Save", leftTitle: "File", rightTitle: "Save",
                                                 leftText: "File\nold", rightText: "Save\nnew",
                                                 titleKey: "Diff — %1$@ ↔ %2$@", titleArguments: ["File", "Save"])
        let panel = OpenDocumentComparePanel(content: content, diff: try .build(left: content.leftText, right: content.rightText))
        defer { panel.close() }
        panel.refreshLocalization(catalog: english)
        panel.leftTextView.setSelectedRange(NSRange(location: 2, length: 3))
        let before = panel.leftTextView.attributedString()
        let root = try #require(panel.window?.contentView)
        panel.refreshLocalization(catalog: korean)
        #expect(panel.window?.contentView === root)
        #expect(panel.leftTextView.attributedString() == before)
        #expect(panel.leftTextView.selectedRange() == NSRange(location: 2, length: 3))
        #expect(panel.window?.title == korean.text("Diff — %1$@ ↔ %2$@", arguments: ["File", "Save"]))
        #expect(panel.leftTextView.accessibilityLabel() == korean.text("%1$@, read-only comparison", arguments: ["File"]))
        #expect(descendants(root).compactMap { $0 as? NSButton }.contains { $0.title == korean.text("Close") })
    }

    @Test func symbolRefreshKeepsFilteredResultsAndSelection() throws {
        let panel = SymbolOutlinePanel()
        panel.refreshLocalization(catalog: english)
        let symbols = [
            DocumentSymbol(name: "File", kind: .function, line: 3, range: .init(location: 0, length: 4)),
            DocumentSymbol(name: "FileTwo", kind: .function, line: 8, range: .init(location: 8, length: 7)),
        ]
        panel.apply(symbols: symbols)
        panel.setQuery("File")
        panel.selectResult(at: 1)
        panel.refreshLocalization(catalog: korean)
        #expect(panel.filteredSymbols == symbols)
        let cell = try #require(panel.tableView(NSTableView(), viewFor: nil, row: 1) as? NSTableCellView)
        #expect(cell.textField?.stringValue == "FileTwo")
        #expect(cell.toolTip == korean.text("%1$@, line %2$@", arguments: [korean.text("Function"), "8"]))
        var selected: DocumentSymbol?
        panel.onActivate = { selected = $0 }
        panel.activateSelectedResult()
        #expect(selected == symbols[1])
    }

    @Test func documentRefreshKeepsUserTitlesAndSelectedTab() throws {
        let tabs = (0..<3).map { index in
            TabSnapshot(id: TabID(), title: "File \(index)", isActive: index == 0, isDirty: true,
                        isPinned: false, buffer: .init(bufferID: BufferID(), revision: 0))
        }
        let panel = DocumentSwitcherPanel()
        panel.refreshLocalization(catalog: english)
        panel.apply(tabs: tabs)
        panel.setQuery("File")
        panel.selectResult(at: 2)
        panel.refreshLocalization(catalog: korean)
        #expect(panel.filteredTabs == tabs)
        #expect(panel.selectedTabID == tabs[2].id)
        let cell = try #require(panel.tableView(NSTableView(), viewFor: nil, row: 2) as? NSTableCellView)
        #expect(cell.textField?.stringValue == "File 2  •")
        #expect(cell.toolTip == korean.text("Unsaved scratch document"))
    }

    @Test func commandRefreshKeepsQueryResultsAndRefreshesMenuPath() throws {
        let menu = NSMenu()
        let root = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "File")
        root.submenu = submenu
        menu.addItem(root)
        let target = NSResponder()
        for title in ["Save", "Save All"] {
            let item = submenu.addItem(withTitle: title, action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
            item.target = target
        }
        let panel = CommandPalettePanel()
        panel.refreshLocalization(catalog: english)
        panel.apply(menu: menu)
        panel.setQuery("Save")
        panel.selectResult(at: 1)
        #expect(panel.filteredCommands.allSatisfy(CommandPaletteRegistry.isCurrentlyEnabled))
        let items = panel.filteredCommands.map { $0.item }
        root.title = korean.text("File")
        items[0].title = korean.text("Save")
        items[1].title = korean.text("Save All")
        panel.refreshLocalization(catalog: korean)
        #expect(panel.filteredCommands.map { $0.item } == items)
        #expect(panel.filteredCommands.allSatisfy { $0.path == korean.text("File") })
        var selected: NSMenuItem?
        panel.onExecute = { item, _ in selected = item }
        withExtendedLifetime(target) { panel.activateSelectedResult() }
        #expect(selected === items[1])
    }

    @Test func extensionsRefreshUpdatesExistingControls() throws {
        let panel = ExtensionsManagerPanel()
        defer { panel.close() }
        panel.render(.init(items: []))
        panel.refreshLocalization(catalog: english)
        let root = try #require(panel.window?.contentView)
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        panel.refreshLocalization(catalog: korean)
        #expect(panel.window?.contentView === root)
        #expect(panel.window?.title == korean.text("Duckpad Extensions"))
        #expect(buttons.contains { $0.title == korean.text("Grant Requested Capabilities") })
        #expect(buttons.contains { $0.title == korean.text("Enable") && !$0.isEnabled })
    }
}
