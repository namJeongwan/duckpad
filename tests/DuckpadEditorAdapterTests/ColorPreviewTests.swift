import AppKit
import DuckpadScintillaBridge
import DuckpadEditorAdapter
import DuckpadDomain
import Testing

@Suite(.serialized)
struct ColorPreviewTests {
    @Test @MainActor func scrollingRemovesOffscreenChipsWithoutAnotherPaint() throws {
        let (window, view) = hosted()
        defer { window.close() }
        let source = "@startuml\nskinparam NoteBackgroundColor #ABCDEF\n" +
            (0..<200).map { "Alice -> Bob: message \($0)\n" }.joined() + "@enduml\n"
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                    folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        view.layoutSubtreeIfNeeded()
        #expect(view.colorPreviewRanges.count == 1)
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        func chips() -> [NSView] { descendants(view).filter { $0.accessibilityIdentifier() == "duckpad.editor.color-chip" } }
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Do not call colorPreviewRanges or display: scrolling must refresh decorations itself.
        #expect(view.firstVisibleLine > 10)
        #expect(chips().isEmpty)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(view.firstVisibleLine == 0)
        #expect(chips().count == 1)
        #expect(!view.canUndo)
    }
    @MainActor private func hosted() -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        view.configureColorPreview(withChangeLabel: "Change color", applyLabel: "Apply")
        return (window, view)
    }
    @Test @MainActor func chipsAreDecorationsAndColorEditsPublishOnceAndUndo() throws {
        let (window, view) = hosted()
        defer { window.close() }
        let source = "@startuml\nskinparam NoteBackgroundColor #FFF7DC\n' comment #ABCDEF\nskinparam NoteBorderColor #D6AC49\nactor \"고객\" #abc\n@enduml\n"
        let original = Data(source.utf8)
        try view.loadUTF8(original, revision: 7)
        #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                   folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        view.layoutSubtreeIfNeeded()
        let reads = view.snapshotReadCount
        let ranges = view.colorPreviewRanges.map(\.rangeValue)
        #expect(ranges.count == 3)
        #expect(view.snapshotReadCount == reads)
        #expect(!view.canUndo)
        let range = try #require(ranges.first)
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 9))
        #expect(view.addSelectionUTF8Range(NSRange(location: 48, length: 0)))
        #expect(view.replaceColor(inUTF8Range: range, with: .red, expectedRevision: 7))
        #expect(view.selectionCount == 2)
        #expect(edits.count == 1)
        #expect(edits.first?.insertedUTF8 == Data("#FF0000".utf8))
        #expect(view.revision == 8)
        #expect(!view.replaceColor(inUTF8Range: range, with: .blue, expectedRevision: 7))
        view.undo()
        #expect(view.contentUTF8 == original)
        view.redo()
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("#FF0000"))
        // Force the native paint path even when the test window is offscreen.
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let style = view.style(atUTF8Position: UInt(range.location))
        #expect(style == 2)
        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false,
                                   folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        #expect(view.colorPreviewRanges.isEmpty)
    }
    @Test @MainActor func shortAlphaColorsAndInvalidTokensAndReadonly() throws {
        let (window, view) = hosted()
        defer { window.close() }
        let source = "@startuml\nrectangle A #F\nrectangle B #abc\nrectangle C #ABCDEF80\nrectangle invalid #ABCDE #ABCDEFz #123456789\n@enduml\n"
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                   folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        view.layoutSubtreeIfNeeded()
        let ranges = view.colorPreviewRanges.map(\.rangeValue)
        #expect(ranges.count == 3)
        let alpha = try #require(ranges.last)
        let replacement = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        #expect(view.replaceColor(inUTF8Range: alpha, with: replacement, expectedRevision: 0))
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("#FF000080"))
        let short = ranges[1]
        #expect(view.replaceColor(inUTF8Range: short, with: .blue, expectedRevision: view.revision))
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("#00f"))
        let translucentShort = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 136.0 / 255)
        #expect(view.replaceColor(inUTF8Range: short, with: translucentShort, expectedRevision: view.revision))
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("#ff000088"))
        view.isInputEnabled = false
        #expect(!view.replaceColor(inUTF8Range: ranges[0], with: .red, expectedRevision: view.revision))
    }
    @Test @MainActor func nativeChooserAppliesAndStaleChooserCloses() throws {
        let (window, view) = hosted()
        defer { window.close() }
        let source = "@startuml\nrectangle A #ABCDEF\n@enduml\n"
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                   folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        view.layoutSubtreeIfNeeded()
        #expect(view.colorPreviewRanges.count == 1)
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        let chip = try #require(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "duckpad.editor.color-chip" })
        chip.performClick(nil)
        let chooser = try #require(NSApplication.shared.windows.compactMap { $0 as? NSColorPanel }
            .first { $0.title == "Change color" })
        defer { chooser.close() }
        chooser.color = .red
        let apply = try #require(chooser.accessoryView?.subviews.compactMap { $0 as? NSButton }.first)
        apply.performClick(nil)
        #expect(!chooser.isVisible)
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("#FF0000"))
        view.undo()
        #expect(view.contentUTF8 == Data(source.utf8))
        _ = view.colorPreviewRanges
        let newChip = try #require(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "duckpad.editor.color-chip" })
        newChip.performClick(nil)
        let pending = try #require(NSApplication.shared.windows.compactMap { $0 as? NSColorPanel }
            .first { $0.title == "Change color" && $0.isVisible })
        view.insertCommittedText("x")
        #expect(!pending.isVisible)
    }
    @Test @MainActor func sharedPaneColorEditPublishesRecoveryOnce() throws {
        let adapter = ScintillaEditorAdapter()
        defer { adapter.invalidate() }
        let id = BufferID()
        adapter.install(.init(bufferID: id, revision: 0, text: "@startuml\nrectangle \"고객\" #ABCDEF\n@enduml\n"))
        adapter.display(.init(bufferID: id, revision: 0))
        adapter.split(orientation: .sideBySide)
        #expect(adapter.applyLanguage(.init(languageID: .init(rawValue: "plantuml"), lexerName: "plantuml",
                                           indentation: .init(width: 4), folding: false, braceMatching: false)))
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        secondary.layoutSubtreeIfNeeded()
        let byteRange = try #require(secondary.contentUTF8.range(of: Data("#ABCDEF".utf8)))
        let range = NSRange(location: byteRange.lowerBound, length: byteRange.count)
        var count = 0
        adapter.onEdit = { edit in count += 1; return .accepted(newRevision: edit.expectedRevision + 1) }
        #expect(secondary.replaceColor(inUTF8Range: range, with: .red, expectedRevision: 0))
        #expect(count == 1)
        #expect(primary.contentUTF8 == secondary.contentUTF8)
        #expect(adapter.recoverySnapshot(for: id)?.utf8 == primary.contentUTF8)
        secondary.undo()
        #expect(String(decoding: primary.contentUTF8, as: UTF8.self).contains("#ABCDEF"))
    }
    @Test @MainActor func colorEditRejectsCompositionInAnySharedPane() throws {
        for composeInPrimary in [true, false] {
            let (window, primary) = hosted()
            defer { window.close() }
            let source = "a #abc Z\n"
            try primary.loadUTF8(Data(source.utf8), revision: 0)
            let peer = DPScintillaEditorView(frame: primary.bounds)
            peer.shareDocument(with: primary)
            primary.onEdit = { peer.synchronizeRevision($0.resultingRevision) }
            for view in [primary, peer] {
                #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                           folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
            }
            let composing = composeInPrimary ? primary : peer
            let editing = composeInPrimary ? peer : primary
            composing.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
            composing.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(composing.hasMarkedText())
            let before = primary.contentUTF8
            #expect(!editing.replaceColor(inUTF8Range: NSRange(location: 2, length: 4),
                                           with: .red, expectedRevision: editing.revision))
            #expect(primary.contentUTF8 == before)
            composing.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
            composing.unmarkText()
            #expect(String(decoding: primary.contentUTF8, as: UTF8.self) == source + "한")
            #expect(editing.replaceColor(inUTF8Range: NSRange(location: 2, length: 4),
                                          with: .red, expectedRevision: editing.revision))
        }
    }
    @Test @MainActor func cssAndJSONColorStringsUseTheSameGutter() throws {
        let (window, view) = hosted()
        defer { window.close() }
        for (lexer, source, count) in [("css", "a { color: #abcd; background: #ABCDEF; } /* #FF0000 */", 2),
                                        ("json", "{\"한글\": \"#ABCDEF\"}", 1)] {
            try view.loadUTF8(Data(source.utf8), revision: 0)
            #expect(view.applyLexerNamed(lexer, keywords: [], tabWidth: 4, useTabs: false,
                                       folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
            view.layoutSubtreeIfNeeded()
            #expect(view.colorPreviewRanges.count == count)
        }
    }
}
