import AppKit
@testable import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct ClipboardPanelTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func deletingSelectedRowsKeepsTheNearestItemAndPreview() throws {
        let panel = ExtensionListPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        let table = try #require(descendants(panel).compactMap { $0 as? NSTableView }.first)
        let delete = try #require(descendants(panel).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("deleteItem") })
        var rows = (0..<60).map { ExtensionListRow(id: String($0), title: "Item \($0)", pinned: false) }
        var previewID = ""
        panel.onEvent = { event, id, _ in
            if event == "delete" { rows.removeAll { $0.id == id }; panel.render(rows, error: nil) }
            if event == "preview" { previewID = id }
        }
        panel.render(rows, error: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        table.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
        table.scrollRowToVisible(40)
        let scrollOrigin = table.visibleRect.minY
        #expect(scrollOrigin > 0)
        #expect(delete.sendAction(delete.action, to: delete.target))
        #expect(table.selectedRow == 40)
        #expect(previewID == "41")
        #expect(abs(table.visibleRect.minY - scrollOrigin) < table.rowHeight)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 40)))
        #expect(delete.sendAction(delete.action, to: delete.target))
        #expect(table.selectedRow == 40)
        #expect(previewID == "42")
        table.selectRowIndexes(IndexSet(integer: rows.count - 1), byExtendingSelection: false)
        #expect(delete.sendAction(delete.action, to: delete.target))
        #expect(table.selectedRow == rows.count - 1)
        #expect(previewID == "58")
        while !rows.isEmpty { _ = delete.sendAction(delete.action, to: delete.target) }
        #expect(table.selectedRow == -1)
        #expect(!delete.isEnabled)
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func clipboardLabelsAndActionsUseEverySupportedLanguage(language: AppLanguage) async throws {
        let panel = ExtensionListPanel()
        let catalog = LocalizationCatalog(language: language)
        panel.refreshLocalization(catalog: catalog)
        let views = descendants(panel)
        let fields = views.compactMap { $0 as? NSTextField }
        for key in ["Clipboard History", "Preview", "Keep history for", "No clipboard history"] {
            #expect(fields.contains { $0.stringValue == catalog.text(key) })
            if language != .english { #expect(catalog.text(key) != key) }
        }
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
        #expect(search.placeholderString == catalog.text("Search clipboard history"))
        let bar = try #require(views.compactMap { $0 as? WrappingButtonBar }.first)
        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map(\.title) == ["Paste", "Paste Next", "Pin", "Delete", "Clear History…"].map { catalog.text($0) })
        let retention = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        #expect(retention.itemArray.map(\.title) == ["1 Day", "3 Days", "1 Week"].map { catalog.text($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        defer { window.contentView = nil; window.close() }
        for width: CGFloat in [500, 300] {
            window.setContentSize(NSSize(width: width, height: 650))
            panel.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
            for button in buttons {
                #expect(button.frame.maxX <= bar.bounds.width + 0.5)
                #expect(button.frame.maxY <= bar.bounds.height + 0.5)
            }
        }
        if language == .japanese, let directory = ProcessInfo.processInfo.environment["DUCKPAD_CLIPBOARD_LOCALIZATION_SCREENSHOTS"] {
            window.setContentSize(NSSize(width: 450, height: 650))
            window.appearance = NSAppearance(named: .darkAqua)
            panel.render([.init(id: "sample", title: "日本語のテスト項目", pinned: false)], error: nil)
            panel.renderPreview("日本語のテスト項目", id: "sample", query: "")
            window.makeKeyAndOrderFront(nil); panel.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), directory + "/clipboard-ja.png"]
            try capture.run(); capture.waitUntilExit()
        }
    }
}
