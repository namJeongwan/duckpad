import AppKit
@testable import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct ListCellAlignmentTests {
    @Test(arguments: AppLanguage.allCases)
    func pendingNativeUpdateIsLocalizedAndAccessible(language: AppLanguage) throws {
        _ = NSApplication.shared
        let manager = ExtensionsManagerPanel()
        defer { manager.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: root.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin/plugin.json")))
        let pending = SemanticVersion(major: 2, minor: 0, patch: 0)
        let item = ExtensionRegistryItem(manifest: manifest, publisherFingerprint: "test", packageDigest: "test", capabilitySchemaDigest: "test", enabled: true, granted: [], issue: nil, pendingVersion: pending)
        manager.render(.init(items: [item]))
        let catalog = LocalizationCatalog(language: language)
        manager.refreshLocalization(catalog: catalog)
        let content = try #require(manager.window?.contentView)
        let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
        let cell = try #require(manager.tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSTableCellView)
        let expected = catalog.text("%1$@ %2$@ · %3$@ · %4$@ applies next launch", arguments: [catalog.text(manifest.name), manifest.version.description, catalog.text("Enabled"), pending.description])
        #expect(cell.textField?.stringValue == expected)
        #expect(cell.toolTip?.contains(expected) == true)
        #expect(cell.accessibilityLabel()?.contains(expected) == true)
        try assertCentered(cell, rowHeight: table.rowHeight)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func assertCentered(_ view: NSView?, rowHeight: CGFloat) throws {
        let cell = try #require(view as? NSTableCellView)
        cell.frame = NSRect(x: 0, y: 0, width: 560, height: rowHeight)
        cell.layoutSubtreeIfNeeded()
        let label = try #require(cell.textField)
        #expect(abs(label.frame.midY - cell.bounds.midY) < 0.6)
        #expect(label.frame.minY >= 0 && label.frame.maxY <= cell.bounds.height)
        #expect(label.maximumNumberOfLines == 1)
    }
    @Test(arguments: [AppLanguage.english, .korean])
    func extensionAndSearchRowsCenterText(language: AppLanguage) async throws {
        _ = NSApplication.shared
        let manager = ExtensionsManagerPanel()
        defer { manager.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: root.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin/plugin.json")))
        manager.render(.init(items: [.init(manifest: manifest, publisherFingerprint: "test", packageDigest: "test", capabilitySchemaDigest: "test", enabled: true, granted: [], issue: nil)]))
        manager.refreshLocalization(catalog: .init(language: language))
        let content = try #require(manager.window?.contentView)
        let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            manager.window?.appearance = NSAppearance(named: appearance)
            let view = manager.tableView(table, viewFor: table.tableColumns.first, row: 0)
            try assertCentered(view, rowHeight: table.rowHeight)
            #expect(view?.toolTip?.contains("test") == true)
            #expect((view as? NSTableCellView)?.textField?.stringValue.contains(LocalizationCatalog(language: language).text("Duckpad Text Tools")) == true)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_LIST_SCREENSHOT_DIR"], let window = manager.window {
                manager.show(relativeTo: nil); window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/extensions-" + language.rawValue + "-" + appearance.rawValue + ".png"]
                try capture.run(); capture.waitUntilExit()
            }
        }
        let search = SearchPanelView(frame: .zero)
        search.refreshLocalization(catalog: .init(language: language))
        let tab = TabID()
        search.present(.init(generation: 1, documents: [.init(tabID: tab, title: "테스트.txt", matches: [
            .init(tabID: tab, bufferID: BufferID(), revision: 0, range: .init(location: 0, length: 1), line: 1, column: 1, snippet: "matched text")
        ])], isTruncated: false, searchedByteCount: 1))
        let resultTable = try #require(descendants(search).compactMap { $0 as? NSTableView }.first)
        for row in 0..<2 {
            try assertCentered(search.tableView(resultTable, viewFor: resultTable.tableColumns.first, row: row), rowHeight: resultTable.rowHeight)
        }
    }
    @Test func clipboardActionsWrapAndUpdateLanguageInPlace() throws {
        let panel = ExtensionListPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        let bar = try #require(descendants(panel).compactMap { $0 as? WrappingButtonBar }.first)
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 5)
        for language in [AppLanguage.english, .korean] {
            let catalog = LocalizationCatalog(language: language)
            panel.refreshLocalization(catalog: catalog)
            #expect(buttons[0].title == catalog.text("Paste"))
            #expect(buttons[1].title == catalog.text("Paste Next"))
            #expect(descendants(panel).compactMap { $0 as? NSTextField }.contains { $0.stringValue == catalog.text("Clipboard History") })
            let retention = try #require(descendants(panel).compactMap { $0 as? NSPopUpButton }.first)
            #expect(retention.itemArray.first?.title == catalog.text("1 Day"))
            for width: CGFloat in [500, 300] {
                window.setContentSize(NSSize(width: width, height: 600))
                panel.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
                let ys = Set(buttons.map { $0.frame.minY })
                #expect(ys.count == (width == 500 ? 1 : 2))
                for button in buttons {
                    #expect(button.frame.minX >= 0 && button.frame.maxX <= bar.bounds.width + 0.5)
                    #expect(button.frame.maxY <= bar.bounds.height + 0.5)
                }
            }
        }
    }

}
