import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchExperienceTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func snapshot(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SNAPSHOTS"] else { return }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit(); #expect(capture.terminationStatus == 0)
    }
    @Test func searchInputsShareFlatChromeAndCenteredTextWhileEditing() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        panel.setQuery(.init(pattern: "한글 ABC", replacement: "오리 ABC", fileMask: "*.swift"))
        defer { panel.dismiss() }
        let window = try #require(panel.window), root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        for suffix in ["find", "replace", "mask"] {
            let field = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + suffix } as? NSTextField)
            #expect(!field.isBezeled && !field.isBordered && !field.drawsBackground)
            #expect(field.focusRingType == .none)
            #expect(field.frame.height == 28)
            let cell = try #require(field.cell)
            let drawing = cell.drawingRect(forBounds: field.bounds)
            #expect(drawing.height < field.bounds.height)
            #expect(abs(drawing.midY - field.bounds.midY) <= 0.5)
            window.makeFirstResponder(field)
            let editor = try #require(field.currentEditor() as? NSTextView)
            let edited = editor.convert(editor.bounds, to: root)
            let expected = field.convert(drawing, to: root)
            #expect(abs(edited.midY - expected.midY) <= 1)
            if suffix != "mask" {
                let icon = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + suffix + ".icon" })
                #expect(abs(expected.midY - icon.convert(icon.bounds, to: root).midY) <= 0.5)
            }
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                window.appearance = NSAppearance(named: appearance)
                try snapshot(window, name: "multi-focused-" + suffix + "-" + appearance.rawValue)
            }
        }
    }
    @Test func referenceInputsKeepIconsOutsideTheTextAndShowReplacement() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let root = try #require(panel.window?.contentView)
        for suffix in ["find", "replace"] {
            let field = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + suffix } as? NSTextField)
            #expect(!(field is NSSearchField))
            let icon = views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + suffix + ".icon" }
            #expect(icon != nil)
            if let icon {
                #expect(icon.convert(icon.bounds, to: root).maxX + 8 <= field.convert(field.bounds, to: root).minX)
            }
            #expect(!field.isHiddenOrHasHiddenAncestor)
            #expect(field.frame.height >= 24)
            #expect(field.placeholderString?.isEmpty == false)
        }
    }
    @Test func emptyReferenceInputsRenderInLightAndDarkAppearance() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let window = try #require(panel.window)
        panel.refreshLocalization(catalog: .init(language: .english))
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            try snapshot(window, name: "multi-empty-" + appearance.rawValue)
        }
    }
    @Test func tabFromSearchGoesDirectlyToReplacementAndShiftTabReturns() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let window = try #require(panel.window), root = try #require(window.contentView)
        let find = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.find" } as? NSTextField)
        let replacement = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.replace" } as? NSTextField)
        window.makeFirstResponder(find)
        let editor = try #require(find.currentEditor() as? NSTextView)
        #expect(panel.control(find, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(window.firstResponder === replacement.currentEditor())
        let nextEditor = try #require(replacement.currentEditor() as? NSTextView)
        #expect(panel.control(replacement, textView: nextEditor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(window.firstResponder === find.currentEditor())
    }
    @Test func referenceFooterAndFileMaskAreVisibleAndHaveUsableHitAreas() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let root = try #require(panel.window?.contentView)
        for identifier in ["mask.enabled", "mask", "replaceOne", "openResults", "previewHeader", "footer"] {
            let view = views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + identifier }
            #expect(view != nil)
            if let view { #expect(!view.isHiddenOrHasHiddenAncestor) }
        }
        for identifier in ["replaceOne", "apply", "openResults"] {
            if let button = views(root).first(where: { $0.accessibilityIdentifier() == "duckpad.multifile." + identifier }) as? NSButton {
                #expect(button.frame.height >= 30)
            }
        }
    }
    private func flags(_ time: Double, _ flags: NSEvent.ModifierFlags, code: UInt16 = 56) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    @Test func maskedResultsKeepTheirScopeWhenMovedToClassicReplaceAll() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let swift = root.appendingPathComponent("source.swift"), txt = root.appendingPathComponent("notes.txt")
        for url in [swift, txt] { try Data("duck duck".utf8).write(to: url) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, fileUseCase: files, searchUseCase: search, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        _ = await files.open(swift); _ = await files.open(txt)
        let swiftTab = try #require(workspace.snapshot().tabs.first { $0.fullPath == swift.path })
        let txtTab = try #require(workspace.snapshot().tabs.first { $0.fullPath == txt.path })
        controller.performReplaceInFiles()
        let panel = controller.searchExperience.multiPanel
        panel.setQuery(.init(pattern: "duck", replacement: "goose", fileMask: "*.swift")); panel.searchPressed()
        for _ in 0..<100 where panel.result == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.result?.documentCount == 1)
        let content = try #require(panel.window?.contentView)
        let open = try #require(views(content).first { $0.accessibilityIdentifier() == "duckpad.multifile.openResults" } as? NSButton)
        _ = NSApp.sendAction(try #require(open.action), to: open.target, from: open)
        controller.searchPanel.show(tab: .replace)
        #expect(controller.searchPanel.currentQuery().fileMask == "*.swift")
        let maskLabel = try #require(views(controller.searchPanel).first { $0.accessibilityIdentifier() == "duckpad.search.file-mask" } as? NSTextField)
        #expect(!maskLabel.isHiddenOrHasHiddenAncestor); #expect(maskLabel.stringValue.contains("*.swift"))
        controller.searchPanel.onReplaceAll?(controller.searchPanel.currentQuery())
        for _ in 0..<100 where editor.snapshot(for: swiftTab.buffer.bufferID)?.text != "goose goose" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.snapshot(for: swiftTab.buffer.bufferID)?.text == "goose goose")
        #expect(editor.snapshot(for: txtTab.buffer.bufferID)?.text == "duck duck")
        #expect(workspace.snapshot().tabs.first { $0.id == txtTab.id }?.isDirty == false)
        for url in [swift, txt] { #expect(try String(contentsOf: url, encoding: .utf8) == "duck duck") }
        // The current-file commands must obey the visible mask too.
        #expect(try await search.replaceAll(.init(pattern: "duck", replacement: "oops", fileMask: "*.swift")) == 0)
        await files.releaseAllSecurityScopedAccess()
    }

    @Test func doubleShiftRequiresTwoCompleteQuickTaps() throws {
        var gesture = DoubleShiftGesture()
        #expect(!gesture.handle(try flags(1, .shift)))
        #expect(!gesture.handle(try flags(1.05, [])))
        #expect(!gesture.handle(try flags(1.2, .shift)))
        #expect(gesture.handle(try flags(1.25, [])))
        #expect(!gesture.handle(try flags(1.3, [])))
        #expect(!gesture.handle(try flags(2, .shift, code: 60)))
        #expect(!gesture.handle(try flags(2.02, [], code: 60)))
        #expect(!gesture.handle(try flags(2.1, .shift, code: 60)))
        #expect(gesture.handle(try flags(2.15, [], code: 60)))
    }
    @Test func doubleShiftIgnoresTypingOtherModifiersAndLongHolds() throws {
        for interruption in [try flags(1.1, [.command], code: 55), try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1.1,
            windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))] {
            var gesture = DoubleShiftGesture()
            _ = gesture.handle(try flags(1, .shift)); _ = gesture.handle(try flags(1.05, []))
            let interrupted = gesture.handle(interruption)
            #expect(!interrupted)
            #expect(!gesture.handle(try flags(1.2, .shift)))
            #expect(!gesture.handle(try flags(1.25, [])))
        }
        var gesture = DoubleShiftGesture()
        _ = gesture.handle(try flags(1, .shift))
        #expect(!gesture.handle(try flags(2, [])))
        _ = gesture.handle(try flags(2.1, .shift))
        #expect(!gesture.handle(try flags(2.15, [])))
    }
    @Test func fileNamesRankNameBeforePathAndNeverSearchContents() {
        let id = WorkspaceRootID()
        func entry(_ name: String, _ path: String) -> FileNameSearchEntry {
            .init(name: name, path: path, target: .workspace(.init(rootID: id, relativePath: path, name: name, kind: .file)))
        }
        let source = [entry("Other.swift", "Duck/Other.swift"), entry("DuckTest.swift", "Tests/DuckTest.swift"),
                      entry("Duck.swift", "Sources/Duck.swift"), entry("한글 문서.txt", "문서/한글 문서.txt"), entry("Café.txt", "Notes/Café.txt")]
        #expect(FileNameSearchEntry.matching(source, query: "duck").map(\.name) == ["DuckTest.swift", "Duck.swift", "Other.swift"])
        #expect(FileNameSearchEntry.matching(source, query: "sources duck").map(\.name) == ["Duck.swift"])
        #expect(FileNameSearchEntry.matching(source, query: "한글 문서").map(\.name) == ["한글 문서.txt"])
        #expect(FileNameSearchEntry.matching(source, query: "CAFE").map(\.name) == ["Café.txt"])
        #expect(FileNameSearchEntry.matching(source, query: "import Foundation").isEmpty)
    }
    @Test func classicFindAndProjectSearchHaveDistinctCommandsAndWindows() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close() }
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let registry = ShortcutRegistry(menu: menu, overrides: [:])
        let global = try #require(registry.entries.first { $0.id == "performFindInFolder:" })
        let replace = try #require(registry.entries.first { $0.id == "performReplaceInFiles:" })
        #expect(global.items.first?.keyEquivalent == "f")
        #expect(global.items.first?.keyEquivalentModifierMask == [.command, .shift])
        #expect(replace.items.first?.keyEquivalent == "r")
        #expect(replace.items.first?.keyEquivalentModifierMask == [.command, .shift])
        #expect(registry.entries.filter { $0.identities.contains(MenuShortcut("cmd+shift+r")!.identity) }.count == 1)
        controller.performShowFind()
        #expect(!controller.searchPanel.isHidden)
        #expect(controller.searchPanel.selectedTab == .find)
        controller.performReplaceInFiles()
        #expect(controller.searchPanel.isHidden)
        #expect(controller.searchExperience.multiPanel.window?.isVisible == true)
        #expect(controller.searchExperience.multiPanel.isReplacing)
        controller.performShowFind()
        #expect(!controller.searchPanel.isHidden)
        #expect(controller.searchExperience.multiPanel.window?.isVisible == false)
    }
    @Test func escapeMenuClosesEachNewPanelFromEveryFocusArea() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        let menu = DuckpadMainMenuFactory.make(target: controller)
        defer { controller.close() }
        for identifier in ["duckpad.multifile.find", "duckpad.multifile.results", "duckpad.multifile.preview", "duckpad.files.query", "duckpad.files.results"] {
            let filename = identifier.hasPrefix("duckpad.files.")
            if filename { controller.performSearchFiles() } else { controller.performFindInFolder() }
            let window = try #require(filename ? controller.searchExperience.filePanel.window : controller.searchExperience.multiPanel.window)
            let root = try #require(window.contentView)
            let target = try #require(views(root).first { $0.accessibilityIdentifier() == identifier })
            _ = window.makeFirstResponder(target)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(menu.performKeyEquivalent(with: escape))
            #expect(!window.isVisible)
        }
    }
    @Test func fileSearchInitialResultsDoNotWaitForWorkspaceIndex() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController()
        var release = false
        panel.onLoad = { while !release { await Task.yield() }; return ([], false, 0) }
        defer { release = true; panel.dismiss() }
        panel.present(in: nil, initial: [.init(name: "한글.txt", path: "/project/한글.txt", target: .tab(TabID()))])
        #expect(panel.results.count == 1)
        panel.setQuery("한글")
        #expect(panel.results.first?.name == "한글.txt")
        panel.dismiss(); release = true
        await Task.yield()
        #expect(panel.window?.isVisible == false)
    }
    @Test func projectSearchDropsLateResultsAfterQueryChangeAndClose() async throws {
        let panel = MultiFileSearchController()
        defer { panel.dismiss() }
        var firstReleased = false
        panel.onSearch = { query, _ in
            if query.pattern == "first" { while !firstReleased { await Task.yield() } }
            let tab = TabID()
            let match = SearchMatch(tabID: tab, bufferID: BufferID(), revision: 0, range: .init(location: 0, length: query.pattern.utf8.count), line: 1, column: 1, snippet: query.pattern)
            return .open(.init(generation: 0, documents: [.init(tabID: tab, title: query.pattern, matches: [match])], isTruncated: false, searchedByteCount: 0))
        }
        panel.setQuery(.init(pattern: "first")); panel.searchPressed()
        await Task.yield()
        panel.setQuery(.init(pattern: "second")); panel.searchPressed()
        for _ in 0..<100 where panel.result == nil { await Task.yield() }
        firstReleased = true
        for _ in 0..<10 { await Task.yield() }
        #expect(panel.rows.first?.title == "second")
        panel.dismiss()
        #expect(panel.window?.isVisible == false)
    }
    @Test func newSearchClearsReplacementSummaryBeforeLanguageRefresh() async throws {
        let panel = MultiFileSearchController(); defer { panel.dismiss() }
        let tab = TabID()
        let preview = MultiFileSearchResults.open(.init(generation: 0, documents: [.init(tabID: tab, title: "old.txt", matches: [])], isTruncated: false, searchedByteCount: 0))
        panel.onReplace = { _, _ in .init(documents: [.init(tabID: tab, title: "old.txt", status: .replaced(1))], wasCancelled: false) }
        panel.applyReplacement(.init(pattern: "old", replacement: "new"), result: preview)
        for _ in 0..<100 where panel.rows.isEmpty { await Task.yield() }
        #expect(panel.rows.first?.title == "old.txt")
        panel.onSearch = { _, _ in
            let match = SearchMatch(tabID: tab, bufferID: BufferID(), revision: 0, range: .init(location: 0, length: 3), line: 1, column: 1, snippet: "new.txt")
            return .open(.init(generation: 0, documents: [.init(tabID: tab, title: "new.txt", matches: [match])], isTruncated: false, searchedByteCount: 0))
        }
        // Keep the same query while explicitly rerunning Find All, as the button does.
        let root = try #require(panel.window?.contentView)
        let field = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.find" } as? NSTextField)
        field.stringValue = "new"
        panel.searchPressed()
        for _ in 0..<100 where panel.result == nil { await Task.yield() }
        panel.refreshLocalization(catalog: .init(language: .korean))
        #expect(panel.rows.first?.title == "new.txt")
    }
    @Test func cancellingFolderPickerRestoresControlsAfterInterruptingSearch() async throws {
        let panel = MultiFileSearchController()
        var release = false
        panel.onSearch = { _, _ in
            while !release { await Task.yield() }
            return .open(.init(generation: 0, documents: [], isTruncated: false, searchedByteCount: 0))
        }
        panel.onChooseFolder = { nil }
        defer { release = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "duck")); panel.searchPressed()
        let root = try #require(panel.window?.contentView)
        let browse = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.browse" } as? NSButton)
        _ = NSApp.sendAction(browse.action!, to: browse.target, from: browse)
        for _ in 0..<10 { await Task.yield() }
        let search = try #require(views(root).compactMap { $0 as? NSButton }.first { $0.action == #selector(MultiFileSearchController.searchPressed) })
        #expect(search.isEnabled)
    }
    @Test func projectSearchPreservesClassicRegexAndExtendedSemantics() {
        let panel = MultiFileSearchController(); defer { panel.dismiss() }
        let query = SearchQuery(pattern: "한글\\r\\n", replacement: "$1", options: .init(mode: .regularExpression, matchCase: true,
            wholeWord: true, dotMatchesNewline: true, scope: .allOpenDocuments))
        panel.setQuery(query)
        #expect(panel.currentQuery() == query)
    }
    @Test func compactSearchOptionsHaveNoCheckboxIndicatorAndFitAtMinimumWidth() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); defer { panel.dismiss() }
        panel.present(replace: true, in: nil)
        let window = try #require(panel.window), root = try #require(window.contentView)
        window.setContentSize(.init(width: 720, height: 460))
        for language in AppLanguage.allCases where language != .system {
            panel.refreshLocalization(catalog: .init(language: language))
            for mode in SearchMode.allCases {
                panel.setQuery(.init(pattern: "workspace", options: .init(mode: mode)))
                root.layoutSubtreeIfNeeded()
                for identifier in ["case", "word", "newline"] {
                    let button = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + identifier } as? NSButton)
                    guard !button.isHiddenOrHasHiddenAncestor else { continue }
                    #expect(button.imagePosition == .noImage)
                    #expect(button.frame.width >= button.intrinsicContentSize.width)
                    let rect = button.convert(button.bounds, to: root)
                    #expect(rect.minX >= 12 && rect.maxX <= root.bounds.width - 12)
                }
            }
        }
    }
    @Test func searchLayoutsFitAllLocalesAndShareResultSpacing() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController()
        let files = FileNameSearchController()
        defer { panel.dismiss(); files.dismiss() }
        let tab = TabID(), buffer = BufferID()
        panel.onSearch = { _, _ in .open(.init(generation: 0, documents: [
            .init(tabID: tab, title: "SessionStore.swift", matches: (0..<12).map { index in
                .init(tabID: tab, bufferID: buffer, revision: 0, range: .init(location: index * 60, length: 9), line: 42 + index, column: 5,
                      snippet: "    let workspace = SessionStore.restore(configuration_\(index))")
            })], isTruncated: false, searchedByteCount: 54)) }
        let context = """
        // Restore the previous workspace without saving source files.
        struct SessionStore {
            let configuration: Configuration

            func restore() -> Workspace {
                let workspace = SessionStore.restore(configuration)
                return workspace
            }
        }
        """
        let prefix = String(context.prefix(through: context.range(of: "let workspace")!.lowerBound).dropLast()) + "let "
        panel.onPreview = { _ in .init(text: context, firstLine: 37, matchLine: 42,
            highlight: .init(location: prefix.utf8.count, length: "workspace".utf8.count)) }
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            panel.present(replace: true, in: nil)
            panel.refreshLocalization(catalog: catalog)
            panel.setQuery(.init(pattern: "workspace", replacement: "session")); panel.searchPressed()
            for _ in 0..<100 where panel.result == nil { await Task.yield() }
            try await Task.sleep(for: .milliseconds(100))
            files.present(in: nil, initial: [.init(name: "SessionStore.swift", path: "/Duckpad/Sources/SessionStore.swift", target: .tab(tab))])
            files.refreshLocalization(catalog: catalog)
            for _ in 0..<10 { await Task.yield() }
            for window in [try #require(panel.window), try #require(files.window)] {
                for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let root = try #require(window.contentView)
                    if window === panel.window {
                        let split = try #require(views(root).first { $0 is SearchResultsSplitView } as? SearchResultsSplitView)
                        #expect(!split.isVertical)
                        #expect(split.subviews[0].frame.height > split.bounds.height * 0.3)
                        #expect(split.subviews[1].frame.height > split.bounds.height * 0.5)
                    }
                    let inputs = views(root).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier() != "duckpad.multifile.mask" }
                    for field in inputs {
                        let rect = field.convert(field.bounds, to: root)
                        #expect(rect.width > 160 && rect.minX >= 0 && rect.maxX <= root.bounds.width + 1)
                        #expect(rect.minY >= 0 && rect.maxY <= root.bounds.height + 1)
                    }
                    if let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SNAPSHOTS"] {
                        let name = window === panel.window ? "multi" : "files"
                        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(language.rawValue)-\(appearance.rawValue).png")
                        window.displayIfNeeded()
                        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
                        try capture.run(); capture.waitUntilExit()
                        #expect(capture.terminationStatus == 0)
                    }
                }
            }
        }
    }
}
