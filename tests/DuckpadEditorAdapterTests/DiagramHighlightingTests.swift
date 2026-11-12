import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct DiagramHighlightingTests {
    private func fixture(_ source: String, lexer: String) throws -> (DPScintillaEditorView, NSWindow) {
        _ = NSApplication.shared
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(DPScintillaEditorView.supportsLexerNamed(lexer))
        #expect(view.applyLexerNamed(lexer, keywords: [], tabWidth: 4, useTabs: false,
                                    folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        return (view, window)
    }
    private func expect(_ tokens: [(String, Int)], source: String, view: DPScintillaEditorView) throws {
        for (token, expected) in tokens {
            let range = try #require(source.range(of: token))
            #expect(view.style(atUTF8Position: UInt(source[..<range.lowerBound].utf8.count)) == expected, "Unexpected diagram style: \(token)")
        }
        for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
            view.apply(palette)
            for style in 1...7 { #expect(view.foregroundColor(forStyle: style) != view.foregroundColor(forStyle: 0)) }
        }
        #expect(view.contentUTF8 == Data(source.utf8) && view.revision == 0 && !view.canUndo)
    }
    @Test func d2CommentsQuotedColorsAndBlockLabelsRetainTheirContext() throws {
        let source = "direction: right\nclient -> server: \"고객\"\n#abc\nclient: {style.fill: \"#fff\"; width: 20}\n\"\"\"\ndirection: hidden\n\"\"\"\nlabel: |md\n# caption\n|\n"
        let (view, window) = try fixture(source, lexer: "d2"); defer { view.invalidate(); window.close() }
        try expect([("direction", 7), ("right", 3), ("->", 5), ("\"고객\"", 4), ("#abc", 1),
                    ("\"#fff\"", 4), ("20", 2), ("direction: hidden", 1), ("# caption", 4)], source: source, view: view)
        let opening = try #require(source.range(of: "\"\"\"")), hidden = try #require(source.range(of: "direction: hidden"))
        try view.replaceUTF8Range(.init(location: source[..<opening.lowerBound].utf8.count, length: 3),
                                  withReplacement: Data("   ".utf8), expectedRevision: 0, resultingRevision: 1)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(view.style(atUTF8Position: UInt(source[..<hidden.lowerBound].utf8.count)) == 7)
    }
    @Test func mermaidHeadsEdgesCommentsStringsAndColorsUseNativeStyling() throws {
        let source = "flowchart LR\n%% comment\nClient[\"고객\"] --> Server\nstyle Client fill:#fff,stroke:#333\n"
        let (view, window) = try fixture(source, lexer: "mermaid"); defer { view.invalidate(); window.close() }
        try expect([("flowchart", 3), ("LR", 3), ("%% comment", 1), ("\"고객\"", 4), ("-->", 5), ("fill", 7), ("#fff", 2)], source: source, view: view)
    }
}
