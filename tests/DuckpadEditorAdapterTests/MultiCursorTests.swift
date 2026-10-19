import AppKit
import Testing
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter

@Suite(.serialized)
struct MultiCursorTests {
    @MainActor private func editor(_ text: String) -> (ScintillaEditorAdapter, BufferID) {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let id = BufferID()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.install(.init(bufferID: id, revision: 0, text: text))
        adapter.display(.init(bufferID: id, revision: 0))
        return (adapter, id)
    }

    @Test @MainActor func nextSkipUndoAndUnicodeTyping() throws {
        let (adapter, id) = editor("한글 한글 한글")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        adapter.perform(.selectNextOccurrence)
        #expect(view.selectionCount == 2)
        adapter.perform(.skipCurrentOccurrence)
        #expect(view.selectionCount == 2)
        #expect(view.caretUTF8Position == 20)
        adapter.perform(.undoAddedSelection)
        #expect(view.selectionCount == 1)
        adapter.perform(.selectAllOccurrences)
        #expect(view.selectionCount == 3)
        view.insertCommittedText("봄")
        #expect(adapter.snapshot(for: id)?.text == "봄 봄 봄")
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "한글 한글 한글")
        adapter.perform(.redo)
        #expect(adapter.snapshot(for: id)?.text == "봄 봄 봄")
        adapter.perform(.collapseSelections)
        #expect(view.selectionCount == 1)
    }

    @Test @MainActor func selectAllFromCaretAndSkipWithoutAnotherMatch() throws {
        let (adapter, _) = editor("word word WORD")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        adapter.perform(.selectAllOccurrences)
        #expect(view.selectionCount == 2)
        adapter.perform(.skipCurrentOccurrence)
        #expect(view.selectionCount == 2)
        view.setPrimarySelectionUTF8Range(NSRange(location: 10, length: 4))
        adapter.perform(.skipCurrentOccurrence)
        #expect(view.selectionCount == 1)
        #expect(view.caretUTF8Position == 14)
    }

    @Test @MainActor func splitCRLFLinesExcludesTrailingBoundary() throws {
        let (adapter, id) = editor("aa\r\nbb\r\ncc")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 8))
        adapter.perform(.splitSelectionIntoLines)
        #expect(view.selectionCount == 2)
        view.insertCommittedText("x")
        #expect(adapter.snapshot(for: id)?.text == "x\r\nx\r\ncc")
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "aa\r\nbb\r\ncc")
    }

    @Test @MainActor func verticalCursorsRetainColumnAcrossShortLine() throws {
        let (adapter, id) = editor("abcd\nx\nabcd")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 3, length: 0))
        adapter.perform(.addCursorBelow)
        adapter.perform(.addCursorBelow)
        #expect(view.selectionCount == 3)
        view.insertCommittedText("!")
        #expect(adapter.snapshot(for: id)?.text == "abc!d\nx  !\nabc!d")
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "abcd\nx\nabcd")
        adapter.setInputEnabled(false)
        #expect(!adapter.canPerform(.addCursorAbove))
    }
}

extension MultiCursorTests {
    @Test(arguments: [false, true]) @MainActor
    func optionDragCreatesRectangleAndEscapeCollapses(pressOptionAfterMouseDown: Bool) throws {
        let (adapter, id) = editor("abcd\nabcd\nabcd")
        let view = try #require(adapter.activeScintillaView)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = adapter.view
        defer { adapter.invalidate(); window.close() }
        window.makeKeyAndOrderFront(nil); view.focusEditor(); window.contentView?.layoutSubtreeIfNeeded()
        let responder = try #require(window.firstResponder as? NSView)
        let client = try #require(responder as? any NSTextInputClient)
        func point(_ offset: Int) -> NSPoint {
            var actual = NSRange()
            let rect = client.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: &actual)
            return window.convertPoint(fromScreen: .init(x: rect.minX + 1, y: rect.midY))
        }
        let start = point(1), end = point(13)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: pressOptionAfterMouseDown ? [] : .option, timestamp: 100, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        responder.mouseDown(with: down)
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: .option, timestamp: 101, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        responder.mouseDragged(with: drag)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: .option, timestamp: 102, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        responder.mouseUp(with: up)
        #expect(view.selectionCount == 3)
        view.insertCommittedText("X")
        #expect(adapter.snapshot(for: id)?.text == "aXd\naXd\naXd")
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 103, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        responder.keyDown(with: escape)
        #expect(view.selectionCount == 1)
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "abcd\nabcd\nabcd")
    }

    @Test @MainActor func commandOptionClickAddsCaretWithoutNavigating() throws {
        let (adapter, id) = editor("abcd\nabcd")
        let view = try #require(adapter.activeScintillaView)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = adapter.view
        defer { adapter.invalidate(); window.close() }
        window.makeKeyAndOrderFront(nil); view.focusEditor(); window.contentView?.layoutSubtreeIfNeeded()
        let responder = try #require(window.firstResponder as? NSView)
        let client = try #require(responder as? any NSTextInputClient)
        var actual = NSRange()
        let rect = client.firstRect(forCharacterRange: NSRange(location: 5, length: 1), actualRange: &actual)
        let point = window.convertPoint(fromScreen: .init(x: rect.minX + 1, y: rect.midY))
        view.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        var navigated = false; view.onDeclarationRequested = { _ in navigated = true }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command, .option], timestamp: 100, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        responder.mouseDown(with: event)
        #expect(view.selectionCount == 2)
        #expect(!navigated)
        view.insertCommittedText("!")
        #expect(adapter.snapshot(for: id)?.text == "!abcd\n!abcd")
    }
}

extension MultiCursorTests {
    @Test @MainActor func markedTextCompositionMirrorsAndUndoesTogether() throws {
        let (adapter, id) = editor("x x")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 0, length: 1))
        adapter.perform(.selectAllOccurrences)
        view.setMarkedText("ㅎ", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!adapter.canPerform(.selectNextOccurrence))
        view.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(adapter.snapshot(for: id)?.text == "한 한")
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "x x")
    }
}

extension MultiCursorTests {
    @Test(arguments: ["xx", "x x", "x\nx"], [false, true]) @MainActor
    func compositionPreservesAdjacentSelectionsAndCancellation(source: String, commit: Bool) throws {
        let (adapter, id) = editor(source)
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 0, length: 1))
        adapter.perform(.selectAllOccurrences)
        view.setMarkedText("ㅎ", selectedRange: .init(location: 0, length: 1), replacementRange: .init(location: NSNotFound, length: 0))
        view.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        if commit {
            let native = try #require(view.value(forKey: "scintilla") as? NSObject)
            let client = try #require(native.value(forKey: "content") as? any NSTextInputClient)
            client.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(adapter.snapshot(for: id)?.text == source.replacingOccurrences(of: "x", with: "한"))
            adapter.perform(.undo)
            #expect(adapter.snapshot(for: id)?.text == source)
            adapter.perform(.redo)
            #expect(adapter.snapshot(for: id)?.text == source.replacingOccurrences(of: "x", with: "한"))
        } else {
            view.setMarkedText("", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
            #expect(adapter.snapshot(for: id)?.text == source)
            #expect(!view.hasMarkedText())
        }
    }
}

extension MultiCursorTests {
    @Test @MainActor func excessiveOccurrenceSelectionPreservesTheOriginalSelection() throws {
        let text = String(repeating: "x ", count: 10_001)
        let (adapter, id) = editor(text)
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 1))
        adapter.perform(.selectAllOccurrences)
        #expect(view.selectionCount == 1)
        #expect(view.caretUTF8Position == 1)
        #expect(adapter.snapshot(for: id)?.text == text)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        adapter.perform(.selectAllOccurrences)
        #expect(view.selectionCount == 1)
        #expect(view.caretUTF8Position == 0)
    }

    @Test @MainActor func excessiveLineSplitPreservesTheOriginalSelection() throws {
        let text = String(repeating: "x\n", count: 10_001)
        let (adapter, id) = editor(text)
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: text.utf8.count))
        adapter.perform(.splitSelectionIntoLines)
        #expect(view.selectionCount == 1)
        #expect(view.caretUTF8Position == text.utf8.count)
        #expect(adapter.snapshot(for: id)?.text == text)
    }
}

extension MultiCursorTests {
    @Test(arguments: [false, true]) @MainActor
    func emptyPrimaryBesideNonemptySelectionUsesANonemptyWord(selectAll: Bool) throws {
        let (adapter, id) = editor("word word word")
        defer { adapter.invalidate() }
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 4))
        #expect(view.addSelectionUTF8Range(NSRange(location: 6, length: 0)))
        #expect(view.selectionCount == 2)
        adapter.perform(selectAll ? .selectAllOccurrences : .selectNextOccurrence)
        #expect(view.selectionCount == (selectAll ? 3 : 1))
        view.insertCommittedText("x")
        #expect(adapter.snapshot(for: id)?.text == (selectAll ? "x x x" : "word x word"))
        adapter.perform(.undo)
        #expect(adapter.snapshot(for: id)?.text == "word word word")
    }
}
