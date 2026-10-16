import AppKit
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct DeclarationViewportTests {
    init() { _ = NSApplication.shared; ScintillaEditorAdapter.prepareResources() }

    @Test(arguments: [240.0, 600.0], [false, true])
    func targetAppearsAtOneFifthOfPane(height: Double, wrapped: Bool) throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.invalidate(); window.close() }
        let prefix = String(repeating: "// context\n", count: 100) + String(repeating: "context ", count: 50)
        let source = prefix + "target" + String(repeating: "\n// following context", count: 100)
        try view.loadUTF8(Data(source.utf8), revision: 0)
        view.isWordWrapEnabled = wrapped
        window.makeKeyAndOrderFront(nil); view.focusEditor(); view.layoutSubtreeIfNeeded()
        let client = try #require(window.firstResponder as? any NSTextInputClient)
        let reads = view.snapshotReadCount
        view.revealDeclaration(in: NSRange(location: prefix.utf8.count, length: 6))
        var actual = NSRange()
        let screenRect = client.firstRect(forCharacterRange: NSRange(location: prefix.utf16.count, length: 1), actualRange: &actual)
        let rect = view.convert(window.convertFromScreen(screenRect), from: nil)
        let distanceFromTop = view.isFlipped ? rect.minY : view.bounds.maxY - rect.maxY
        #expect(distanceFromTop / view.bounds.height >= 0.10)
        #expect(distanceFromTop / view.bounds.height <= 0.25)
        #expect(view.firstVisibleLine > 0)
        #expect(view.anchorUTF8Position == prefix.utf8.count)
        #expect(view.caretUTF8Position == prefix.utf8.count + 6)
        #expect(view.revision == 0 && !view.canUndo)
        #expect(view.snapshotReadCount == reads)
        view.revealDeclaration(in: NSRange(location: 0, length: 0))
        #expect(view.firstVisibleLine == 0)
    }

    @Test func targetInsideFoldIsExpanded() throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        defer { view.invalidate() }
        let prefix = String(repeating: "// context\n", count: 30) + "void outer() {\n"
        try view.loadUTF8(Data((prefix + "void target() {}\n}\n" + String(repeating: "// following\n", count: 60)).utf8), revision: 0)
        #expect(view.applyLexerNamed("cpp", keywords: [], tabWidth: 4, useTabs: false, folding: true, braceMatching: false, maximumStyleBytes: 100_000))
        view.toggleFold(atLine: 30)
        #expect(!view.isFoldExpanded(atLine: 30))
        view.revealDeclaration(in: NSRange(location: prefix.utf8.count + 5, length: 6))
        #expect(view.isFoldExpanded(atLine: 30))
        #expect(view.revision == 0 && !view.canUndo)
    }
}
