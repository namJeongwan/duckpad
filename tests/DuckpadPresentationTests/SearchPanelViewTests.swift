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

    @Test func typingAndMarkedEditsDoNotRequestDialogResizing() throws {
        let (window, panel) = host(width: 640, replace: false, language: .korean)
        defer { panel.hide(); window.contentView = nil; window.close() }
        let field = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.find" } as? NSTextField)
        var layouts = 0
        panel.onLayoutChanged = { layouts += 1 }
        for text in ["a", "ab", "사용중", "사용", "유후", "유ㅎ", "유휴"] {
            field.stringValue = text
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(panel.currentQuery().pattern == text)
        }
        let empty = SearchResultSet(generation: 1, documents: [], isTruncated: false, searchedByteCount: 0)
        panel.present(empty, showsResults: false)
        #expect(layouts == 0)
    }

    @Test func folderRowsAreClearedBeforeHiddenIncrementalPresentation() throws {
        let (window, panel) = host(width: 640, replace: false, language: .english)
        defer { panel.hide(); window.contentView = nil; window.close() }
        let identity = FileIdentity(canonicalPath: "/tmp/a.txt", device: 1, inode: 2, byteCount: 4, modifiedNanoseconds: 0, contentToken: "fixture")
        panel.present(FolderSearchResultSet(rootPath: "/tmp", documents: [.init(path: "/tmp/a.txt", relativePath: "a.txt", identity: identity,
            matches: [.init(range: .init(location: 0, length: 1), line: 1, column: 1, snippet: "duck")])], isTruncated: false,
            searchedFileCount: 1, skippedFileCount: 0, searchedByteCount: 4))
        let table = try #require(descendants(panel).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 2)
        panel.present(SearchResultSet(generation: 2, documents: [], isTruncated: false, searchedByteCount: 4), showsResults: false)
        #expect(table.numberOfRows == 0)
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
        // This checks delivery, not latency; native suites can occupy MainActor
        // beyond the debounce interval while the scheduled refresh waits.
        for _ in 0..<100 {
            if !queries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        let selection = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.replace-scope" })
        let matchCase = try #require(views.first { $0.accessibilityIdentifier() == "duckpad.search.match-case" })
        let rect = selection.convert(selection.bounds, to: panel)
        // Scope stays below both labeled fields and above the native search options.
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
        // Ending query editing must not dispatch navigation when an option takes focus.
        if let action = field.action { field.sendAction(action, to: field.target) }
        selection.performClick(nil)
        #expect(navigations == 0)
        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(navigations == 1)
        #expect(panel.currentQuery().options.scope == .selection)
        panel.hide()
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func replacementScopeAndSummaryFitAllLanguages(language: AppLanguage) throws {
        let (window, panel) = host(width: 640, replace: true, language: language)
        defer { panel.hide(); window.contentView = nil; window.close() }
        let scope = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace-scope" } as? NSPopUpButton)
        var queries: [SearchQuery] = []
        panel.onReplaceAll = { queries.append($0) }
        for index in 0..<3 {
            scope.selectItem(at: index)
            scope.sendAction(scope.action, to: scope.target)
            #expect(panel.currentQuery().options.scope == [SearchScope.document, .selection, .allOpenDocuments][index])
            let buttons = descendants(panel).compactMap { $0 as? NSButton }
            let current = try #require(buttons.first { $0.accessibilityIdentifier() == "duckpad.search.replace-current" })
            #expect(current.isEnabled == (index != 2))
        }
        let replaceAll = try #require(descendants(panel).compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("replaceAllPressed")
        })
        replaceAll.performClick(nil)
        #expect(queries.last?.options.scope == .allOpenDocuments)
        panel.present(OpenDocumentsReplacementResult(documents: [
            .init(tabID: TabID(), title: "한글_문서.txt", status: .replaced(12)),
            .init(tabID: TabID(), title: "readonly.json", status: .readOnly),
            .init(tabID: TabID(), title: "new 1", status: .noChanges)
        ], wasCancelled: false))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.numberOfRows(in: NSTableView()) == 3)
        let field = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.replace" } as? NSTextField)
        let caption = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.label.Replace with" } as? NSTextField)
        #expect(caption.stringValue == LocalizationCatalog(language: language).text("Replace with"))
        #expect(caption.bounds.width >= caption.intrinsicContentSize.width)
        #expect(field.bounds.width >= 100)
        for control in descendants(panel).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            let rect = control.convert(control.bounds, to: panel)
            #expect(rect.minX >= -1 && rect.maxX <= panel.bounds.width + 1)
        }
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_REPLACE_SNAPSHOTS"] {
            window.setContentSize(NSSize(width: 640, height: panel.fittingSize.height))
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            let url = URL(fileURLWithPath: directory).appendingPathComponent("replace-\(language.rawValue).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try capture.run(); capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }

    @Test func replacementProgressSurvivesEditorRefreshAndCancellation() async throws {
        let panel = SearchPanelView(frame: .zero)
        panel.refreshLocalization(catalog: LocalizationCatalog(language: .english))
        panel.show(replace: true, selectedText: "duck")
        panel.setSearchInProgress(true)
        panel.present(OpenDocumentsReplacementResult(documents: [
            .init(tabID: TabID(), title: "new 1", status: .replaced(2))
        ], wasCancelled: false))
        var refreshes = 0
        panel.onIncrementalQuery = { _ in refreshes += 1 }
        panel.refreshMatchesAfterDocumentChange()
        try await Task.sleep(for: .milliseconds(250))
        #expect(refreshes == 0)
        let cancel = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.cancel" } as? NSButton)
        cancel.performClick(nil)
        let status = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.status" } as? NSTextField)
        #expect(status.stringValue.contains("Cancelled"))
        #expect(status.stringValue.contains("Replacements: 2"))
        #expect(panel.numberOfRows(in: NSTableView()) == 1)
        panel.hide()
    }

}
