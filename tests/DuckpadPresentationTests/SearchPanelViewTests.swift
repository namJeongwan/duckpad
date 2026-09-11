import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchPanelViewTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func host(width: CGFloat, replace: Bool, language: AppLanguage) -> (NSWindow, SearchPanelView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let panel = SearchPanelView(frame: .zero)
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        window.contentView = root
        panel.refreshLocalization(catalog: LocalizationCatalog(language: language))
        panel.show(replace: replace, selectedText: "duck")
        root.layoutSubtreeIfNeeded()
        return (window, panel)
    }

    @Test(arguments: [AppLanguage.english, .korean])
    func dialogControlsFitWithoutHorizontalScrolling(language: AppLanguage) throws {
        let (window, panel) = host(width: 640, replace: true, language: language)
        defer { window.contentView = nil; window.close() }
        let views = descendants(panel)
        #expect(!views.compactMap { $0 as? NSScrollView }.contains { $0.hasHorizontalScroller })
        for control in views.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            let rect = control.convert(control.bounds, to: panel)
            #expect(rect.minX >= -1 && rect.maxX <= panel.bounds.width + 1)
            #expect(rect.minY >= -1 && rect.maxY <= panel.bounds.height + 1)
        }
        let find = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.find" })
        let replacement = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.replace" })
        #expect(!find.convert(find.bounds, to: panel).intersects(replacement.convert(replacement.bounds, to: panel)))
        #expect(find.convert(find.bounds, to: panel).minY != replacement.convert(replacement.bounds, to: panel).minY)
    }

    @Test func changingMatchOptionsInvalidatesAndRefreshesResults() async throws {
        let panel = SearchPanelView(frame: .zero)
        panel.refreshLocalization(catalog: LocalizationCatalog(language: .english))
        panel.show(replace: false, selectedText: "duck")
        let matchCase = try #require(descendants(panel).compactMap { $0 as? NSButton }.first {
            $0.title == "Match case" || $0.accessibilityIdentifier() == "duckpad.search.match-case"
        })
        var invalidations = 0
        var queries: [SearchQuery] = []
        panel.onQueryInvalidated = { invalidations += 1 }
        panel.onIncrementalQuery = { queries.append($0) }
        matchCase.performClick(nil)
        #expect(invalidations == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(queries.count == 1)
        #expect(queries.first?.options.matchCase == true)
        panel.hide()
    }
    @Test func fourTabsRetainInputsAndShowOnlyRelevantActions() throws {
        let (window, panel) = host(width: 640, replace: true, language: .english)
        defer { window.contentView = nil; window.close() }
        let replacement = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace" } as? NSTextField)
        replacement.stringValue = "오리"
        let modes = descendants(panel).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier().hasPrefix("duckpad.search.mode.") == true }
        try #require(modes.first { $0.tag == 2 }).performClick(nil)
        let dot = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.dot-newline" } as? NSButton)
        #expect(dot.isEnabled)
        dot.performClick(nil)
        panel.setFolderURL(URL(fileURLWithPath: "/tmp/duckpad-search-fixture"))
        for tab in [SearchPanelView.Tab.find, .replace, .folder, .bookmarks] {
            panel.show(tab: tab)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(panel.currentQuery().pattern == "duck")
            #expect(panel.currentQuery().replacement == "오리")
            #expect(panel.currentQuery().options.mode == .regularExpression)
            #expect(panel.currentQuery().options.dotMatchesNewline)
            #expect(panel.folderURL?.path == "/tmp/duckpad-search-fixture")
            #expect(replacement.isHiddenOrHasHiddenAncestor == (tab != .replace))
            let controls = descendants(panel).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
            for control in controls {
                let rect = control.convert(control.bounds, to: panel)
                #expect(rect.minX >= -1 && rect.maxX <= panel.bounds.width + 1)
                #expect(rect.minY >= -1 && rect.maxY <= panel.bounds.height + 1)
            }
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SNAPSHOTS"] {
                for language in [AppLanguage.english, .korean] {
                    panel.refreshLocalization(catalog: LocalizationCatalog(language: language))
                    window.title = panel.windowTitle
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        window.appearance = NSAppearance(named: appearance)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.setContentSize(NSSize(width: 640, height: panel.fittingSize.height))
                        window.makeKeyAndOrderFront(nil)
                        window.displayIfNeeded()
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                        let url = URL(fileURLWithPath: directory).appendingPathComponent("search-\(tab.rawValue)-\(language.rawValue)-\(appearance.rawValue).png")
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
                        try capture.run()
                        capture.waitUntilExit()
                        #expect(capture.terminationStatus == 0)
                    }
                }
            }
        }
        try #require(modes.first { $0.tag == 0 }).performClick(nil)
        #expect(!dot.isEnabled)
        #expect(!panel.currentQuery().options.dotMatchesNewline)
        panel.hide()
    }

    @Test func explicitScopesAndBookmarkActionsUseTheCurrentQuery() throws {
        let panel = SearchPanelView(frame: .zero)
        panel.refreshLocalization(catalog: LocalizationCatalog(language: .english))
        panel.show(replace: false, selectedText: "duck")
        let controls = descendants(panel).compactMap { $0 as? NSButton }
        var scopes: [SearchScope] = []
        panel.onFindAll = { scopes.append($0.options.scope) }
        try #require(controls.first { $0.accessibilityIdentifier() == "duckpad.search.selection" }).performClick(nil)
        try #require(controls.first { $0.title == "Find all in current document" }).performClick(nil)
        try #require(controls.first { $0.title == "Find all in open documents" }).performClick(nil)
        #expect(scopes == [.selection, .allOpenDocuments])
        panel.show(tab: .bookmarks)
        var marked: SearchQuery?
        var clearsPrevious = false
        panel.onMarkAll = { marked = $0; clearsPrevious = $1 }
        try #require(controls.first { $0.title == "Clear previous bookmarks" }).performClick(nil)
        try #require(controls.first { $0.title == "Bookmark matching lines" }).performClick(nil)
        #expect(marked?.pattern == "duck")
        #expect(marked?.options.scope == .selection)
        #expect(clearsPrevious)
        panel.hide()
    }

    @Test func searchWindowClosesAndReopensWithoutResizingTheEditor() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let panel = SearchPanelView(frame: .zero)
        let controller = SearchWindowController(searchView: panel)
        defer { controller.dismiss(); parent.close() }
        panel.onClose = { controller.dismiss() }
        let before = parent.contentLayoutRect
        panel.show(replace: false, selectedText: "한글")
        controller.present(in: parent)
        #expect(controller.window?.parent === parent)
        #expect(parent.contentLayoutRect == before)
        panel.cancelOperation(nil)
        #expect(controller.window?.isVisible == false)
        #expect(panel.isHidden)
        panel.show(replace: true)
        controller.present(in: parent)
        #expect(controller.window?.isVisible == true)
        #expect(panel.currentQuery().pattern == "한글")
        #expect(parent.contentLayoutRect == before)
        panel.onClose = nil
    }

    @Test(arguments: [AppLanguage.english, .korean])
    func referenceFormFitsCompactDialog(language: AppLanguage) throws {
        let (window, panel) = host(width: 640, replace: true, language: language)
        defer { window.contentView = nil; window.close() }
        #expect(panel.fittingSize.width <= 640)
        #expect(panel.fittingSize.height <= 330)
        let views = descendants(panel)
        let replacement = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.replace" })
        let selection = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.selection" })
        let matchCase = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.match-case" })
        let rect = selection.convert(selection.bounds, to: panel)
        // Selection scope belongs just below the fields, above the match options.
        #expect(rect.midY > matchCase.convert(matchCase.bounds, to: panel).midY)
        #expect(rect.midY < replacement.convert(replacement.bounds, to: panel).midY)
    }

    @Test func directionCountAndOpacityControlsApplyWithoutChangingTheQueryText() throws {
        let panel = SearchPanelView(frame: .zero)
        panel.refreshLocalization(catalog: LocalizationCatalog(language: .english))
        panel.show(replace: false, selectedText: "return")
        let controls = descendants(panel).compactMap { $0 as? NSButton }
        try #require(controls.first { $0.accessibilityIdentifier() == "duckpad.search.backwards" }).performClick(nil)
        #expect(panel.currentQuery().options.direction == .backward)
        #expect(panel.currentQuery(direction: .forward).options.direction == .forward)
        var countQuery: SearchQuery?
        panel.onIncrementalQuery = { countQuery = $0 }
        try #require(controls.first { $0.title == "Count matches" }).performClick(nil)
        #expect(countQuery?.pattern == "return")
        #expect(countQuery?.options.direction == .backward)

        let appearance = panel.appearanceOptions
        let enabled = try #require(controls.first { $0.accessibilityIdentifier() == "duckpad.search.opacity.enabled" })
        let always = try #require(controls.first { $0.accessibilityIdentifier() == "duckpad.search.opacity.always" })
        let slider = try #require(descendants(appearance).compactMap { $0 as? NSSlider }.first)
        #expect(appearance.windowAlpha(isKeyWindow: false) == 1)
        #expect(!slider.isEnabled)
        enabled.performClick(nil)
        #expect(slider.isEnabled)
        #expect(appearance.windowAlpha(isKeyWindow: true) == 1)
        #expect(appearance.windowAlpha(isKeyWindow: false) == 0.75)
        always.performClick(nil)
        #expect(appearance.windowAlpha(isKeyWindow: true) == 0.75)
        slider.doubleValue = slider.minValue
        #expect(appearance.windowAlpha(isKeyWindow: false) >= 0.5)
        enabled.performClick(nil)
        #expect(appearance.windowAlpha(isKeyWindow: false) == 1)
        #expect(panel.currentQuery().pattern == "return")
        panel.hide()
    }

    @Test func leavingTheQueryFieldForSelectionScopeDoesNotNavigate() throws {
        let (window, panel) = host(width: 640, replace: false, language: .english)
        defer { window.contentView = nil; window.close() }
        let field = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.find" } as? NSSearchField)
        let selection = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.selection" } as? NSButton)
        var navigations = 0
        panel.onFind = { _ in navigations += 1 }
        // NSSearchField can send its action when editing ends as a checkbox takes focus.
        if let action = field.action { field.sendAction(action, to: field.target) }
        selection.performClick(nil)
        #expect(navigations == 0)
        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(navigations == 1)
        #expect(panel.currentQuery().options.scope == .selection)
        panel.hide()
    }

}
