import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct WordOccurrenceHighlightTests {
    private func editor(_ text: String) throws -> DPScintillaEditorView {
        _ = NSApplication.shared
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        try view.loadUTF8(Data(text.utf8), revision: 7)
        return view
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }

    @Test func partialSelectionHighlightsSubstringsAndPublishesScrollbarTicks() async throws {
        let view = try editor("apple orange apple pineapple Apple\nap apricot")
        defer { view.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        try await settle()
        for offset: UInt in [0, 13, 23, 35, 38] {
            #expect(view.isWordHighlighted(atUTF8Position: offset))
            #expect(view.isWordHighlighted(atUTF8Position: offset + 1))
            #expect(!view.isWordHighlighted(atUTF8Position: offset + 2))
        }
        #expect(!view.isWordHighlighted(atUTF8Position: 29))
        #expect(view.searchOverviewPositions.count == 5)
        #expect(view.anchorUTF8Position == 0)
        #expect(view.caretUTF8Position == 2)
        #expect(!view.canUndo)
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: 6, length: 6))], revision: 7))
        #expect(view.searchOverviewPositions.count == 1)
        view.clearSearchHighlights()
        #expect(view.searchOverviewPositions.count == 5)
        view.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 1))
        try await settle()
        #expect(view.searchOverviewPositions.isEmpty)
        #expect(!view.isWordHighlighted(atUTF8Position: 0))
    }

    @Test func fullDocumentScanIncludesOffscreenAndChunkBoundaryMatches() async throws {
        let source = "ap\n" + String(repeating: ".", count: 65_532) + "apple\n"
            + String(repeating: ".\n", count: 70_000) + "ap"
        let view = try editor(source)
        defer { view.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        for _ in 0..<200 {
            if view.searchOverviewPositions.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.searchOverviewPositions.count == 3)
        #expect(view.isWordHighlighted(atUTF8Position: 65_535))
        #expect(view.isWordHighlighted(atUTF8Position: UInt(source.utf8.count - 2)))
        #expect(view.wordHighlightInspectedByteCount <= 64 * 1024 + 256)
        try view.loadUTF8(Data("pear pear".utf8), revision: 7)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        try await settle()
        #expect(view.searchOverviewPositions.count == 2)
        #expect(view.isWordHighlighted(atUTF8Position: 5))
    }

    @Test func clickingOccurrenceTickPreservesPartialSelection() async throws {
        let source = "apple\n" + String(repeating: "orange\n", count: 150) + "apple"
        let view = try editor(source)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        try await settle()
        view.layoutSubtreeIfNeeded()
        func descendants(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(descendants) }
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        let fraction = try #require(view.searchOverviewPositions.last).doubleValue
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX, y: fraction * (overlay.bounds.height - 3) + 1.5), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: event)
        #expect(view.anchorUTF8Position == source.utf8.count - 5)
        #expect(view.caretUTF8Position == source.utf8.count - 3)
        #expect(view.firstVisibleLine > 0)
        try await settle()
        #expect(view.searchOverviewPositions.count == 2)
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(!view.isWordHighlighted(atUTF8Position: 2))
        #expect(!view.canUndo)
    }

    @Test func reloadCancelsAnInFlightDocumentScan() async throws {
        let view = try editor(String(repeating: "apple ", count: 200_000))
        defer { view.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        for _ in 0..<200 {
            if view.isWordHighlighted(atUTF8Position: 0) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        try view.loadUTF8(Data("pear pear".utf8), revision: 7)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        try await settle()
        #expect(view.searchOverviewPositions.count == 2)
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 5))
        #expect(!view.isWordHighlighted(atUTF8Position: 2))
        #expect(!view.canUndo)
    }

    @Test func caretHighlightsWholeWordsAndClearsOnWhitespaceWithoutEditing() async throws {
        let view = try editor("apple orange apple pineapple Apple  ")
        defer { view.invalidate() }
        let reads = view.snapshotReadCount
        view.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 0))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 13))
        #expect(!view.isWordHighlighted(atUTF8Position: 23))
        #expect(!view.isWordHighlighted(atUTF8Position: 29))
        #expect(view.caretUTF8Position == 2)
        #expect(view.anchorUTF8Position == 2)
        #expect(view.revision == 7)
        #expect(!view.canUndo)
        #expect(view.snapshotReadCount == reads)
        view.setPrimarySelectionUTF8Range(NSRange(location: 8, length: 0))
        try await settle()
        #expect(!view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 6))
        view.setPrimarySelectionUTF8Range(NSRange(location: 35, length: 0))
        try await settle()
        #expect(!view.isWordHighlighted(atUTF8Position: 6))
    }

    @Test func wholeSelectionUnicodeAndSearchDecorationsCoexist() async throws {
        let view = try editor("한글 한글 한글자\nfoo_bar foo_bar\ncafé café")
        defer { view.invalidate() }
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: 7, length: 6))], revision: 7))
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 7))
        #expect(view.isWordHighlighted(atUTF8Position: 14))
        #expect(view.searchOverviewPositions.count == 1)
        #expect(view.isSearchHighlighted(atUTF8Position: 7))
        view.clearSearchHighlights()
        #expect(view.searchOverviewPositions.count == 3)
        #expect(view.isWordHighlighted(atUTF8Position: 7))
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 7))
        #expect(!view.isWordHighlighted(atUTF8Position: 10))
        view.setPrimarySelectionUTF8Range(NSRange(location: 24, length: 7))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 32))
        view.setPrimarySelectionUTF8Range(NSRange(location: 40, length: 5))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 46))
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 13))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.searchOverviewPositions.count == 1)
    }

    @Test func repeatedRapidSelectionsUseLatestCaretAndReloadDropsOldWord() async throws {
        let view = try editor("apple orange apple orange")
        defer { view.invalidate() }
        for _ in 0..<20 {
            view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
            view.setPrimarySelectionUTF8Range(NSRange(location: 7, length: 0))
        }
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 6))
        #expect(view.isWordHighlighted(atUTF8Position: 19))
        #expect(!view.isWordHighlighted(atUTF8Position: 0))
        try view.loadUTF8(Data("pear pear".utf8), revision: 7)
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 5))
        #expect(!view.isWordHighlighted(atUTF8Position: 4))
    }

    @Test func multipleSelectionsAndSharedPanesKeepSelectionsIntact() async throws {
        let view = try editor("apple orange apple orange")
        let clone = DPScintillaEditorView(frame: view.frame)
        clone.shareDocument(with: view)
        defer { clone.invalidate(); view.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 5))
        #expect(view.addSelectionUTF8Range(NSRange(location: 13, length: 5)))
        let caret = view.caretUTF8Position
        try await settle()
        #expect(view.selectionCount == 2)
        #expect(view.caretUTF8Position == caret)
        #expect(clone.isWordHighlighted(atUTF8Position: 0))
        clone.setPrimarySelectionUTF8Range(NSRange(location: 7, length: 0))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 6))
        #expect(view.isWordHighlighted(atUTF8Position: 19))
        #expect(!view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.selectionCount == 2)
        #expect(view.caretUTF8Position == caret)
        #expect(!view.canUndo)
    }

    @Test func largeDocumentsUseBoundedChunksAndSkipEnormousTokens() async throws {
        let view = try editor(String(repeating: "apple orange apple\n", count: 30_000))
        defer { view.invalidate() }
        let reads = view.snapshotReadCount
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        for _ in 0..<500 {
            if view.searchOverviewPositions.count == 60_000 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.searchOverviewPositions.count == 60_000)
        #expect(view.isWordHighlighted(atUTF8Position: 569_994))
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.wordHighlightInspectedByteCount <= 64 * 1024 + 256)
        view.setPrimarySelectionUTF8Range(NSRange(location: 400_008, length: 0))
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 400_007))
        #expect(view.wordHighlightInspectedByteCount <= 256 * 1024)
        #expect(view.snapshotReadCount == reads)
        try view.loadUTF8(Data(String(repeating: "x", count: 1_000_000).utf8), revision: 8)
        view.setPrimarySelectionUTF8Range(NSRange(location: 500_000, length: 0))
        try await settle()
        #expect(view.wordHighlightInspectedByteCount == 0)
        #expect(!view.isWordHighlighted(atUTF8Position: 500_000))
    }

    @Test func pendingRefreshAfterInvalidationDoesNotTouchReleasedEditor() async throws {
        let view = try editor("apple apple")
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        view.invalidate()
        try await settle()
    }

    @Test func editsUndoAndMarkedTextRefreshWithoutChangingUndoHistory() async throws {
        let view = try editor("apple apple 한")
        defer { view.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 5))
        try await settle()
        view.beginGroupedUndo()
        view.insertCommittedText("pear")
        view.endGroupedUndo()
        try await settle()
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(!view.isWordHighlighted(atUTF8Position: 5))
        view.undo()
        try await settle()
        #expect(view.contentUTF8 == Data("apple apple 한".utf8))
        #expect(view.isWordHighlighted(atUTF8Position: 6))
        #expect(!view.canUndo)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 5))
        view.beginGroupedUndo()
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        #expect(!view.isWordHighlighted(atUTF8Position: 0))
        #expect(!view.isWordHighlighted(atUTF8Position: 4))
        view.insertCommittedText("한")
        view.endGroupedUndo()
        try await settle()
        #expect(view.contentUTF8 == Data("한 apple 한".utf8))
        #expect(view.isWordHighlighted(atUTF8Position: 0))
        #expect(view.isWordHighlighted(atUTF8Position: 10))
        view.undo()
        #expect(view.contentUTF8 == Data("apple apple 한".utf8))
    }
}
