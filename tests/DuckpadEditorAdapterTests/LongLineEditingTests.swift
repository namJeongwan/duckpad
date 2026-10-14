import AppKit
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
@MainActor
struct LongLineEditingTests {
    init() { _ = NSApplication.shared; ScintillaEditorAdapter.prepareResources() }

    private func makeView(_ text: String) throws -> DPScintillaEditorView {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.isWordWrapEnabled = false
        try view.loadUTF8(Data(text.utf8), revision: 0)
        #expect(view.applyLexerNamed("json", keywords: ["false null true"], tabWidth: 4,
            useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 16 * 1024 * 1024))
        // Replacement's fold refresh styles the complete line, including its tail.
        try view.replaceUTF8Range(.init(location: text.utf8.count, length: 0), withReplacement: Data(),
            expectedRevision: view.revision, resultingRevision: view.revision + 1)
        return view
    }

    @Test func incrementalLongJSONMatchesFreshLexingAfterEditsAndUndo() throws {
        let item = #"{"name":"value","url":"https://example.com/a","iri":"abc:def","flag":true,"count":12,"empty":null}"#
        var text = "[" + Array(repeating: item, count: 800).joined(separator: ",") + "]"
        let view = try makeView(text)
        defer { view.invalidate() }
        var step = 0
        func compare() throws {
            let fresh = try makeView(text)
            defer { fresh.invalidate() }
            #expect(view.contentUTF8 == Data(text.utf8))
            let actual = (0..<text.utf8.count).map { view.style(atUTF8Position: UInt($0)) }
            let expected = (0..<text.utf8.count).map { fresh.style(atUTF8Position: UInt($0)) }
            let stylesMatch = actual == expected
            if !stylesMatch {
                let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                print("LONG_JSON step=\(step) mismatch=\(String(describing: mismatch)) lines=\(view.lineCount)")
            }
            #expect(stylesMatch)
            for line in 0..<view.lineCount {
                #expect(view.foldLevel(atLine: line) == fresh.foldLevel(atLine: line))
            }
        }
        func replace(_ range: NSRange, _ replacement: String) throws {
            step += 1
            var bytes = Data(text.utf8)
            bytes.replaceSubrange(range.location..<NSMaxRange(range), with: replacement.utf8)
            text = String(decoding: bytes, as: UTF8.self)
            try view.replaceUTF8Range(range, withReplacement: Data(replacement.utf8),
                expectedRevision: view.revision, resultingRevision: view.revision + 1)
            if view.lineCount > 1 {
                try view.replaceUTF8Range(.init(location: text.utf8.count, length: 0), withReplacement: Data(),
                    expectedRevision: view.revision, resultingRevision: view.revision + 1)
            }
            try compare()
        }
        let middle = 1 + (item.utf8.count + 1) * 400
        // String content, escaping, structure, and errors which propagate to EOF.
        for insertion in ["a", "한🦆", "\\", "\"", "]", " ", "\n"] {
            let before = text
            try replace(.init(location: middle + 11, length: 0), insertion)
            try replace(.init(location: middle + 11, length: insertion.utf8.count), "")
            #expect(text == before)
        }
        try replace(.init(location: middle + item.utf8.count - 1, length: 0), "a")
        try replace(.init(location: middle + item.utf8.count, length: 0), "a")
        try replace(.init(location: middle + item.utf8.count - 1, length: 2), "")
        // Deletion spanning cached regions must update both brace positions and levels.
        try replace(.init(location: middle, length: item.utf8.count + 1), "")
        let before = text
        view.beginGroupedUndo()
        try replace(.init(location: 10, length: 0), "a")
        view.endGroupedUndo()
        view.undo()
        text = before
        // Refresh without resetting the lexer's cache.
        try view.replaceUTF8Range(.init(location: 0, length: 0), withReplacement: Data(),
            expectedRevision: view.revision, resultingRevision: view.revision + 1)
        try compare()
    }

    @Test func asciiCoordinatesStayFastAndCorrectAcrossUnicodeTabsAndUndo() throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.invalidate(); window.close() }
        let text = String(repeating: "a", count: 3 * 1024 * 1024)
        try view.loadUTF8(Data(text.utf8), revision: 0)
        view.isWordWrapEnabled = false
        let position = text.utf8.count / 2
        view.setPrimarySelectionUTF8Range(.init(location: position, length: 0))
        view.focusEditor()
        let client = try #require(window.firstResponder as? any NSTextInputClient)
        let start = ContinuousClock.now
        for _ in 0..<32 {
            #expect(client.selectedRange() == NSRange(location: position, length: 0))
            var actual = NSRange()
            #expect(client.attributedSubstring(forProposedRange: .init(location: position - 2, length: 2),
                actualRange: &actual)?.string == "aa")
            #expect(view.caretColumn == position)
        }
        #expect(start.duration(to: .now) < .milliseconds(200), "ASCII queries must not rescan the long line")
        view.beginGroupedUndo()
        view.insertCommittedText("한🦆\t")
        view.endGroupedUndo()
        #expect(client.selectedRange() == NSRange(location: position + 4, length: 0))
        let tabWidth = Int(view.configuredTabWidth)
        #expect(view.caretColumn == ((position + 2) / tabWidth + 1) * tabWidth)
        view.undo()
        #expect(view.contentUTF8 == Data(text.utf8))
        #expect(client.selectedRange() == NSRange(location: position, length: 0))
        #expect(view.caretColumn == position)
        view.redo()
        #expect(client.selectedRange() == NSRange(location: position + 4, length: 0))
        try view.loadUTF8(Data("a\r\nb\tc".utf8), revision: view.revision + 1)
        view.setPrimarySelectionUTF8Range(.init(location: 6, length: 0))
        #expect(view.caretColumn == view.configuredTabWidth + 1)
    }

    @Test func longBraceMatchingPreservesStylesBothDirectionsAndUndo() throws {
        for padding in [4094, 4095, 4096, 65536] {
            // Braces in string values must not affect the outer structural pair.
            let text = "{\"value\":\"" + String(repeating: "x", count: padding)
                + "}한🦆{\",\"nested\":{\"n\":1}}"
            let view = try makeView(text)
            defer { view.invalidate() }
            let last = text.utf8.count - 1
            func expectPair(_ caret: Int, _ brace: Int, _ match: Int) {
                view.setPrimarySelectionUTF8Range(.init(location: caret, length: 0))
                view.updateBraceHighlight()
                #expect(view.highlightedBraceUTF8Position == brace)
                #expect(view.matchingBraceUTF8Position == match)
                #expect(view.badBraceUTF8Position == -1)
            }
            expectPair(0, 0, last)
            expectPair(last + 1, last, 0)
            view.beginGroupedUndo()
            try view.replaceUTF8Range(.init(location: last, length: 1), withReplacement: Data(),
                expectedRevision: view.revision, resultingRevision: view.revision + 1)
            view.endGroupedUndo()
            view.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
            view.updateBraceHighlight()
            #expect(view.badBraceUTF8Position == 0)
            view.undo()
            #expect(view.contentUTF8 == Data(text.utf8))
            // Undo defers styling until drawing. This unhosted view explicitly
            // refreshes it before checking the style-sensitive brace match.
            try view.replaceUTF8Range(.init(location: 0, length: 0), withReplacement: Data(),
                expectedRevision: view.revision, resultingRevision: view.revision + 1)
            expectPair(0, 0, last)
        }
    }

    @Test(arguments: [false, true])
    func batchedNativeInputPreservesMultipleCaretsOvertypeAndUndo(overtype: Bool) throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.invalidate(); window.close() }
        let original = Data(String(repeating: "a", count: 70000).utf8)
        try view.loadUTF8(original, revision: 0)
        view.isWordWrapEnabled = true
        view.additionalSelectionTyping = true
        view.overtype = overtype
        view.setPrimarySelectionUTF8Range(.init(location: 10, length: 0))
        #expect(view.addSelectionUTF8Range(.init(location: 50000, length: 0)))
        view.focusEditor()
        let input = try #require(window.firstResponder as? any NSTextInputClient)
        let insertion = "xy한🦆z"
        view.beginGroupedUndo()
        input.insertText(insertion, replacementRange: .init(location: NSNotFound, length: 0))
        view.endGroupedUndo()
        var expected = original
        for position in [50000, 10] {
            let replaced = overtype ? insertion.unicodeScalars.count : 0
            expected.replaceSubrange(position..<(position + replaced), with: insertion.utf8)
        }
        #expect(view.selectionCount == 2)
        #expect(view.contentUTF8 == expected)
        view.undo()
        #expect(view.contentUTF8 == original)
        view.redo()
        #expect(view.contentUTF8 == expected)
    }
}
