import AppKit
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct ExtensionCatalogViewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @Test func searchLocalizationAndInstalledAction() throws {
        _ = NSApplication.shared
        let view = ExtensionCatalogView()
        let id = ExtensionID(rawValue: "com.duckpad.clipboard-history")
        let release = ExtensionUpdate(extensionID: id, version: .init(major: 0, minor: 2, patch: 1), downloadURL: URL(string: "https://github.com/a/b/releases/download/v0.2.1/plugin.zip")!, sha256: "test", publisherID: "com.duckpad", keyID: "test")
        let plugin = ExtensionCatalogPlugin(name: "Clipboard History", descriptions: ["en": "Find clipboard text", "ko": "클립보드 텍스트 검색"], release: release, publisherFingerprint: "test")
        let ko = LocalizationCatalog(language: .korean)
        view.refreshLocalization(catalog: ko)
        view.render([plugin], installed: [], loading: false, busy: false, statusKey: "")
        let search = try #require(descendants(view).compactMap { $0 as? NSSearchField }.first)
        let table = try #require(descendants(view).compactMap { $0 as? NSTableView }.first)
        let button = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "duckpad.extensions.catalog.install" })
        #expect(table.numberOfRows == 1 && button.isEnabled)
        search.stringValue = "클립보드"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(table.numberOfRows == 1)
        search.stringValue = "no matching plugin"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(table.numberOfRows == 0 && !button.isEnabled)
        search.stringValue = ""
        view.render([plugin], installed: [id], loading: false, busy: false, statusKey: "")
        #expect(!button.isEnabled && button.title == ko.text("Installed"))
        view.render([plugin], installed: [], loading: true, busy: false, statusKey: "Loading Plugin Catalog…")
        #expect(!button.isEnabled)
        view.render([plugin], installed: [], loading: false, busy: false, statusKey: "Could Not Load Plugin Catalog")
        let retry = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "duckpad.extensions.catalog.refresh" })
        var retried = false; view.onReload = { retried = true }; retry.performClick(nil)
        #expect(retried)
    }
    @Test(arguments: [AppLanguage.german, .japanese, .korean])
    func catalogAndInstalledControlsFitSmallWindow(language: AppLanguage) throws {
        _ = NSApplication.shared
        let panel = ExtensionsManagerPanel()
        defer { panel.close() }
        panel.refreshLocalization(catalog: .init(language: language))
        let window = try #require(panel.window)
        window.setContentSize(NSSize(width: 500, height: 420))
        let root = try #require(window.contentView)
        let sections = try #require(descendants(root).compactMap { $0 as? NSSegmentedControl }.first)
        for section in 0...1 {
            sections.selectedSegment = section
            _ = NSApplication.shared.sendAction(sections.action!, to: sections.target, from: sections)
            root.layoutSubtreeIfNeeded()
            for button in descendants(root).compactMap({ $0 as? NSButton }) where !button.isHiddenOrHasHiddenAncestor {
                let frame = button.convert(button.bounds, to: root)
                #expect(frame.minX >= 0 && frame.maxX <= root.bounds.width + 1)
                #expect(frame.minY >= 0 && frame.maxY <= root.bounds.height + 1)
            }
        }
    }
    @Test func changingInstallationTitleReflowsButtonsWithoutResizing() throws {
        _ = NSApplication.shared
        let panel = ExtensionsManagerPanel()
        defer { panel.close() }
        let window = try #require(panel.window)
        window.setContentSize(NSSize(width: 500, height: 420))
        let root = try #require(window.contentView)
        let sections = try #require(descendants(root).compactMap { $0 as? NSSegmentedControl }.first)
        sections.selectedSegment = 1
        _ = NSApplication.shared.sendAction(sections.action!, to: sections.target, from: sections)
        for language in [AppLanguage.english, .german, .japanese] {
            panel.refreshLocalization(catalog: .init(language: language))
            for busy in [false, true, false] {
                panel.catalogView.render([], installed: [], loading: false, busy: busy, statusKey: "")
                root.layoutSubtreeIfNeeded()
                let buttons = descendants(panel.catalogView).compactMap { $0 as? NSButton }
                for button in buttons {
                    #expect(button.frame.width >= ceil(button.intrinsicContentSize.width))
                    #expect(button.frame.maxX <= (button.superview?.bounds.width ?? 0) + 1)
                }
            }
        }
    }

}
