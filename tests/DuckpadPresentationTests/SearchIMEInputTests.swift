import AppKit
import DuckpadApplication
import DuckpadInfrastructure
import DuckpadDomain
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchIMEInputTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    @Test func projectSearchTracksKoreanMarkedTextWithoutNeedingSpaceOrBackspace() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); defer { panel.dismiss() }
        var queries: [String] = []
        let snapshot = SearchBufferSnapshot(tabID: TabID(), title: "IME.txt", bufferID: BufferID(), revision: 0, utf8: Data("사용중 유후 유휴".utf8))
        panel.onSearch = { query, _ in
            queries.append(query.pattern)
            let matches = try SearchEngine.matches(in: snapshot, query: query, regexEngine: ICURegexEngine())
            return .open(.init(generation: 0, documents: [.init(tabID: snapshot.tabID, title: snapshot.title, matches: matches)], isTruncated: false, searchedByteCount: snapshot.utf8.count))
        }
        panel.present(replace: true, in: nil)
        let root = try #require(panel.window?.contentView)
        let field = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.find" } as? NSTextField)
        panel.window?.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for text in ["사용중", "유후", "유ㅎ", "유휴"] {
            editor.setMarkedText(text, selectedRange: .init(location: (text as NSString).length, length: 0), replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            try await wait { queries.last == text && panel.result != nil }
            #expect(panel.result?.matchCount == (text == "유ㅎ" ? 0 : 1))
            #expect(editor.hasMarkedText())
            #expect(editor.selectedRange().location == (text as NSString).length)
        }
        editor.unmarkText()
        try await wait { queries.last == "유휴" }
    }
    @Test func classicFindTracksKoreanCompositionWithoutCommittingIt() async throws {
        _ = NSApplication.shared
        let panel = SearchPanelView(frame: .zero), controller = SearchWindowController(searchView: panel)
        defer { controller.dismiss() }
        var queries: [String] = []
        panel.onIncrementalQuery = { queries.append($0.pattern) }
        panel.show(replace: false); controller.present(in: nil)
        let field = try #require(views(panel).first { $0.accessibilityIdentifier() == "duckpad.search.find" } as? NSTextField)
        controller.window?.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for text in ["사용중", "유후", "유ㅎ", "유휴"] {
            editor.setMarkedText(text, selectedRange: .init(location: (text as NSString).length, length: 0), replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            try await wait { queries.last == text }
            #expect(editor.hasMarkedText())
        }
    }

    @Test func filenameSearchRefreshesDuringKoreanComposition() throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController()
        panel.present(in: nil, initial: ["사용중", "유후", "유휴"].map {
            .init(name: $0 + ".txt", path: "/fixtures/" + $0 + ".txt", target: .tab(TabID()))
        })
        defer { panel.dismiss() }
        let root = try #require(panel.window?.contentView)
        let field = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.files.query" } as? NSTextField)
        panel.window?.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for text in ["사용중", "유후", "유ㅎ", "유휴"] {
            editor.setMarkedText(text, selectedRange: .init(location: (text as NSString).length, length: 0), replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            #expect(panel.results.map(\.name) == (text == "유ㅎ" ? [] : [text + ".txt"]))
            #expect(editor.hasMarkedText())
        }
    }

    @Test func compositionCommitUndoRedoAndFieldChangesPreserveNativeEditing() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let root = try #require(panel.window?.contentView)
        let find = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.find" } as? NSTextField)
        let replacement = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.replace" } as? NSTextField)
        panel.window?.makeFirstResponder(find)
        let editor = try #require(find.currentEditor() as? NSTextView)
        editor.insertText("original", replacementRange: .init(location: 0, length: 0))
        let undo = try #require(editor.undoManager)
        undo.removeAllActions(); undo.beginUndoGrouping()
        editor.setMarkedText("유후", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: 8))
        editor.setMarkedText("유휴", selectedRange: .init(location: 2, length: 0), replacementRange: editor.markedRange())
        #expect(editor.hasMarkedText())
        editor.insertText("유휴", replacementRange: editor.markedRange())
        undo.endUndoGrouping()
        #expect(!editor.hasMarkedText()); #expect(find.stringValue == "유휴")
        #expect(undo.canUndo); undo.undo(); #expect(editor.string == "original")
        #expect(undo.canRedo); undo.redo(); #expect(editor.string == "유휴")
        editor.setMarkedText("사용중", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: 0, length: 2))
        #expect(editor.hasMarkedText())
        panel.window?.makeFirstResponder(replacement)
        let other = try #require(replacement.currentEditor() as? NSTextView)
        #expect(other !== editor); #expect(!other.hasMarkedText()); #expect(other.string.isEmpty)
        other.insertText("오리", replacementRange: .init(location: 0, length: 0))
        #expect(find.stringValue == "사용중"); #expect(replacement.stringValue == "오리")
    }

    @Test func commandPaletteFiltersKoreanCompositionAndClearsCancelledComposition() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = try #require(window.contentView), palette = CommandPaletteView(frame: .zero)
        let target = NSTextView(), menu = NSMenu()
        for name in ["사용중", "유후", "유휴"] {
            let item = menu.addItem(withTitle: name, action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "")
            item.target = target
        }
        window.makeKeyAndOrderFront(nil); palette.present(menu: menu, in: host)
        defer { palette.dismiss(); window.close() }
        let field = try #require(views(palette).first { $0.accessibilityIdentifier() == "duckpad.commands.search" } as? NSTextField)
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for text in ["사용중", "유후", "유ㅎ", "유휴"] {
            editor.setMarkedText(text, selectedRange: .init(location: (text as NSString).length, length: 0), replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            #expect(palette.filteredCommands.map(\.item.title) == (text == "유ㅎ" ? [] : [text]))
            #expect(editor.hasMarkedText())
        }
        // Input methods can cancel marked text by replacing it with an empty marked string.
        editor.setMarkedText("", selectedRange: .init(location: 0, length: 0), replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText()); #expect(editor.string.isEmpty)
        #expect(palette.filteredCommands.count == 3)
    }

}
