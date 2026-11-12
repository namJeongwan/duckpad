import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct SearchResultViewportTests {
    @MainActor private final class Fixture {
        let editor = ScintillaEditorAdapter()
        let window: NSWindow
        let view: DPScintillaEditorView
        let source: String

        init(_ source: String, width: CGFloat = 420, height: CGFloat = 280, wrapped: Bool = false,
             buffer: EditorBufferDescriptor? = nil) throws {
            _ = NSApplication.shared
            self.source = source
            let buffer = buffer ?? EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: source))
            editor.display(buffer)
            view = try #require(editor.activeScintillaView)
            view.isWordWrapEnabled = wrapped
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.view
            window.makeKeyAndOrderFront(nil)
            view.focusEditor()
            editor.view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        func dispose() { editor.invalidate(); window.contentView = nil; window.close() }

        func rect(at offset: Int, in target: DPScintillaEditorView? = nil) throws -> NSRect {
            let prefix = String(decoding: source.utf8.prefix(offset), as: UTF8.self)
            let client = try #require(window.firstResponder as? any NSTextInputClient)
            let screen = client.firstRect(forCharacterRange: .init(location: prefix.utf16.count, length: 0), actualRange: nil)
            return (target ?? view).convert(window.convertFromScreen(screen), from: nil)
        }

        var viewport: NSRect { viewport(for: view) }

        func viewport(for view: DPScintillaEditorView) -> NSRect {
            func scroll(_ parent: NSView) -> NSScrollView? {
                if let parent = parent as? NSScrollView { return parent }
                return parent.subviews.lazy.compactMap(scroll).first
            }
            guard let clip = scroll(view)?.contentView else { return .zero }
            return view.convert(clip.bounds, from: clip)
        }

        func expectContext(_ range: SearchUTF8Range, rows: CGFloat = 2, in target: DPScintillaEditorView? = nil) throws {
            let view = target ?? self.view
            let start = try rect(at: range.location, in: view), end = try rect(at: range.location + range.length, in: view)
            let bounds = viewport(for: view)
            let top = view.isFlipped ? min(start.minY, end.minY) - bounds.minY : bounds.maxY - max(start.maxY, end.maxY)
            let bottom = view.isFlipped ? bounds.maxY - max(start.maxY, end.maxY) : min(start.minY, end.minY) - bounds.minY
            #expect(start.height > 0 && bounds.height > 0)
            #expect(top >= rows * start.height - 1, "Search start needs visible context above")
            #expect(bottom >= rows * start.height - 1, "Search end needs visible context below")
            #expect(view.anchorUTF8Position == range.location)
            #expect(view.caretUTF8Position == range.location + range.length)
            #expect(view.revision == 0 && !view.canUndo)
        }
    }

    @Test func distantMatchesKeepContextAboveAndBelowInEitherDirection() throws {
        let lines = (0..<220).map { "row \($0): match\n" }
        let fixture = try Fixture(lines.joined())
        defer { fixture.dispose() }
        let reads = fixture.view.snapshotReadCount
        for line in [140, 30, 170, 60] {
            let match = SearchUTF8Range(location: lines.prefix(line).joined().utf8.count + "row \(line): ".utf8.count, length: 5)
            fixture.editor.selectAndRevealSearchMatch(match)
            try fixture.expectContext(match)
        }
        #expect(fixture.view.snapshotReadCount == reads)
    }

    @Test func nearbyVisibleMatchesDoNotMoveTheViewport() throws {
        let fixture = try Fixture(String(repeating: "match\n", count: 220))
        defer { fixture.dispose() }
        fixture.editor.selectAndRevealSearchMatch(.init(location: 100 * 6, length: 5))
        let first = fixture.view.firstVisibleLine
        fixture.editor.selectAndRevealSearchMatch(.init(location: 99 * 6, length: 5))
        #expect(fixture.view.firstVisibleLine == first)
    }

    @Test func wrappedMultilineMatchKeepsBothEndsVisible() async throws {
        let prefix = String(repeating: "한글 문맥 ", count: 150)
        let match = "BEGIN " + String(repeating: "word ", count: 14) + "END"
        let fixture = try Fixture(prefix + match + String(repeating: " 뒤쪽 문맥", count: 100), width: 300, height: 340, wrapped: true)
        defer { fixture.dispose() }
        try await Task.sleep(for: .milliseconds(60))
        let range = SearchUTF8Range(location: prefix.utf8.count, length: match.utf8.count)
        fixture.editor.selectAndRevealSearchMatch(range)
        try fixture.expectContext(range)
    }

    @Test func hiddenSearchMatchUnfoldsItsContainingRegion() throws {
        let prefix = String(repeating: "// context\n", count: 30) + "void outer() {\n"
        let fixture = try Fixture(prefix + "    target();\n}\n" + String(repeating: "// context\n", count: 80))
        defer { fixture.dispose() }
        #expect(fixture.view.applyLexerNamed("cpp", keywords: [], tabWidth: 4, useTabs: false, folding: true, braceMatching: false, maximumStyleBytes: 100_000))
        fixture.view.toggleFold(atLine: 30)
        #expect(!fixture.view.isFoldExpanded(atLine: 30))
        let range = SearchUTF8Range(location: prefix.utf8.count + 4, length: 6)
        fixture.editor.selectAndRevealSearchMatch(range)
        #expect(fixture.view.isFoldExpanded(atLine: 30))
        try fixture.expectContext(range)
    }

    @Test func matchNearDocumentBoundariesRemainsVisible() throws {
        let source = String(repeating: "match\n", count: 120)
        let fixture = try Fixture(source, height: 160)
        defer { fixture.dispose() }
        for offset in [source.utf8.count - 6, 0] {
            fixture.editor.selectAndRevealSearchMatch(.init(location: offset, length: 5))
            let start = try fixture.rect(at: offset), end = try fixture.rect(at: offset + 5)
            #expect(fixture.viewport.contains(start))
            #expect(fixture.viewport.contains(end))
        }
    }

    @Test func horizontallyScrolledMatchKeepsBothEndsVisible() throws {
        let prefix = String(repeating: "x", count: 400)
        let fixture = try Fixture(prefix + "MATCH_START match MATCH_END" + String(repeating: "z", count: 200))
        defer { fixture.dispose() }
        let range = SearchUTF8Range(location: prefix.utf8.count, length: "MATCH_START match MATCH_END".utf8.count)
        fixture.editor.selectAndRevealSearchMatch(range)
        #expect(fixture.viewport.contains(try fixture.rect(at: range.location)))
        #expect(fixture.viewport.contains(try fixture.rect(at: range.location + range.length)))
        #expect(fixture.view.horizontalScrollOffset > 0)
    }

    @Test func oversizedMultilineMatchKeepsItsCaretAndSmallPanesStayUsable() throws {
        let fixture = try Fixture(String(repeating: "match\n", count: 220), height: 90)
        defer { fixture.dispose() }
        let range = SearchUTF8Range(location: 40 * 6, length: 100 * 6)
        fixture.editor.selectAndRevealSearchMatch(range)
        #expect(fixture.viewport.contains(try fixture.rect(at: range.location + range.length)))
        #expect(fixture.view.anchorUTF8Position == range.location)
        #expect(fixture.view.caretUTF8Position == range.location + range.length)
        #expect(fixture.view.revision == 0 && !fixture.view.canUndo)
        fixture.editor.selectAndRevealSearchMatch(.init(location: 70 * 6, length: 0))
        #expect(fixture.viewport.contains(try fixture.rect(at: 70 * 6)))
    }

    @Test func invalidSearchRangesCannotChangeSelectionOrViewport() throws {
        let fixture = try Fixture("한글\n" + String(repeating: "match\n", count: 220))
        defer { fixture.dispose() }
        fixture.editor.selectAndRevealSearchMatch(.init(location: 7 + 100 * 6, length: 5))
        let first = fixture.view.firstVisibleLine, caret = fixture.view.caretUTF8Position
        for range in [SearchUTF8Range(location: -1, length: 0), .init(location: 1, length: 1),
                      .init(location: Int.max, length: Int.max), .init(location: 0, length: Int.max)] {
            fixture.editor.selectAndRevealSearchMatch(range)
            #expect(fixture.view.firstVisibleLine == first && fixture.view.caretUTF8Position == caret)
        }
    }

    @Test func findNextPreviousAndResultActivationUseSearchContext() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let source = (0..<220).map { [30, 170].contains($0) ? "needle\n" : "context\n" }.joined()
        let fixture = try Fixture(source, buffer: try #require(workspace.snapshot().activeBuffer))
        defer { fixture.dispose() }
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: fixture.editor, regexEngine: ICURegexEngine())
        let query = SearchQuery(pattern: "needle")
        let first = try #require(try await search.find(query))
        try fixture.expectContext(first)
        let second = try #require(try await search.find(query))
        #expect(second.location > first.location)
        try fixture.expectContext(second)
        let previous = try #require(try await search.find(.init(pattern: "needle", options: .init(direction: .backward))))
        #expect(previous == first)
        try fixture.expectContext(previous)
        let results = try await search.findAll(query)
        let selected = try #require(results.documents.first?.matches.last)
        try await search.activate(selected)
        try fixture.expectContext(selected.range)
    }

    @Test func searchScrollsOnlyTheFocusedSplitPane() throws {
        let fixture = try Fixture(String(repeating: "match\n", count: 220), width: 700)
        defer { fixture.dispose() }
        fixture.editor.split(orientation: .sideBySide)
        fixture.editor.view.layoutSubtreeIfNeeded()
        let secondary = try #require(fixture.editor.secondaryScintillaView)
        fixture.view.focusEditor()
        fixture.view.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        let first = fixture.view.firstVisibleLine
        secondary.focusEditor()
        #expect(fixture.editor.activeScintillaView === secondary)
        let range = SearchUTF8Range(location: 150 * 6, length: 5)
        fixture.editor.selectAndRevealSearchMatch(range)
        try fixture.expectContext(range, in: secondary)
        #expect(fixture.view.firstVisibleLine == first)
        #expect(fixture.view.caretUTF8Position == 0)
    }
}
