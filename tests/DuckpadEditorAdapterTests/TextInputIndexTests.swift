import AppKit
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
@MainActor
struct TextInputIndexTests {
    init() { _ = NSApplication.shared; ScintillaEditorAdapter.prepareResources() }

    @Test(arguments: [false, true])
    func repeatedInputManagerQueriesAtEndDoNotScanWholeDocument(replacingBinary: Bool) async throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.invalidate(); window.close() }
        let text = String(repeating: "hello한글🦆\n", count: 1_000_000) + "tail한🦆"
        let bytes = Data(text.utf8)
        let length = (text as NSString).length
        if replacingBinary {
            let binary = try await DPScintillaBinaryDocument.prepare(data: Data([0, 1, 2]))
            view.load(binary, revision: 0)
        }
        try view.loadUTF8(bytes, revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: bytes.count, length: 0))
        view.focusEditor()
        let client = try #require(window.firstResponder as? any NSTextInputClient)
        let start = ContinuousClock.now
        for _ in 0..<32 {
            #expect(client.selectedRange() == NSRange(location: length, length: 0))
            var actual = NSRange(location: NSNotFound, length: 0)
            #expect(client.attributedSubstring(forProposedRange: NSRange(location: length - 3, length: 3),
                actualRange: &actual)?.string == "한🦆")
        }
        let elapsed = start.duration(to: .now)
        print("INPUT_INDEX query_32=\(elapsed)")
        #expect(elapsed < .seconds(2), "Input-manager queries must not scan every preceding line")
    }

    @Test func inputRangesStayCorrectAcrossUnicodeEditsUndoAndReload() throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.invalidate(); window.close() }
        let original = "A한🦆\r\nBé\n끝🙂"
        try view.loadUTF8(Data(original.utf8), revision: 0)
        view.focusEditor()
        let client = try #require(window.firstResponder as? any NSTextInputClient)
        func check(_ expected: String) throws {
            var byteOffset = 0
            var utf16Offset = 0
            for scalar in expected.unicodeScalars {
                let unit = String(scalar)
                view.setPrimarySelectionUTF8Range(NSRange(location: byteOffset, length: unit.utf8.count))
                #expect(client.selectedRange() == NSRange(location: utf16Offset, length: unit.utf16.count))
                var actual = NSRange(location: NSNotFound, length: 0)
                #expect(client.attributedSubstring(forProposedRange: .init(location: utf16Offset, length: unit.utf16.count),
                    actualRange: &actual)?.string == unit)
                byteOffset += unit.utf8.count
                utf16Offset += unit.utf16.count
            }
            view.setPrimarySelectionUTF8Range(NSRange(location: byteOffset, length: 0))
            #expect(client.selectedRange() == NSRange(location: utf16Offset, length: 0))
        }
        try check(original)
        view.beginGroupedUndo()
        client.insertText("중간🦆\n", replacementRange: .init(location: 6, length: 2))
        view.endGroupedUndo()
        let replaced = (original as NSString).replacingCharacters(in: NSRange(location: 6, length: 2), with: "중간🦆\n")
        #expect(view.contentUTF8 == Data(replaced.utf8))
        try check(replaced)
        view.undo()
        #expect(view.contentUTF8 == Data(original.utf8))
        try check(original)
        view.redo()
        try check(replaced)
        try view.loadUTF8(Data("새 문서🦆\n마지막".utf8), revision: view.revision + 1)
        try check("새 문서🦆\n마지막")
        client.setMarkedText("ㅎ", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        client.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        client.insertText("한", replacementRange: .init(location: NSNotFound, length: 0))
        try check("새 문서🦆\n마지막한")

        let peer = DPScintillaEditorView(frame: view.frame)
        defer { peer.invalidate() }
        peer.shareDocument(with: view)
        window.contentView = peer
        peer.focusEditor()
        let peerClient = try #require(window.firstResponder as? any NSTextInputClient)
        view.insertCommittedText("\n다음🦆")
        let shared = "새 문서🦆\n마지막한\n다음🦆"
        peer.setPrimarySelectionUTF8Range(NSRange(location: shared.utf8.count, length: 0))
        #expect(peerClient.selectedRange() == NSRange(location: shared.utf16.count, length: 0))
        window.contentView = view
        peer.invalidate()
        try check(shared)

        try view.loadUTF8(Data("A🦆Z\n끝".utf8), revision: view.revision + 1)
        // Preserve Scintilla's existing adjustment of a proposed range that
        // splits a UTF-16 surrogate pair; Cocoa receives the actual range.
        var actual = NSRange(location: NSNotFound, length: 0)
        #expect(client.attributedSubstring(forProposedRange: .init(location: 1, length: 1), actualRange: &actual)?.string == "🦆Z\n끝")
        #expect(actual == NSRange(location: 1, length: 5))
        #expect(client.attributedSubstring(forProposedRange: .init(location: 2, length: 0), actualRange: &actual)?.string == "")
        #expect(actual == NSRange(location: 6, length: 0))
    }
}
