import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
struct PlantUMLHighlightingTests {
    @Test @MainActor func plantUMLTokensAndIncrementalComments() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window.contentView?.addSubview(view)
        let source = "@startuml\nskinparam NoteBackgroundColor #FFF7DC\nactor \"고객\" as Customer\nCustomer --> SCA: \"안내\"\n/' comment\nactor hidden\n'/\nautonumber 13\n@enduml\n"
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(DPScintillaEditorView.supportsLexerNamed("plantuml"))
        guard view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                  folding: false, braceMatching: false, maximumStyleBytes: 1_000_000) else {
            Issue.record("PlantUML lexer is missing")
            return
        }
        for (token, style) in [("@startuml", 3), ("skinparam", 3), ("NoteBackgroundColor", 7),
                               ("#FFF7DC", 2), ("\"고객\"", 4), ("-->", 5), ("actor hidden", 1), ("13", 2)] {
            let range = try #require(source.range(of: token))
            #expect(view.style(atUTF8Position: UInt(source[..<range.lowerBound].utf8.count)) == style)
        }
        for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
            view.apply(palette)
            for style in 1...7 {
                #expect(view.foregroundColor(forStyle: style) != view.foregroundColor(forStyle: 0))
            }
        }
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(!view.canUndo)
        let opening = try #require(source.range(of: "/'"))
        let offset = source[..<opening.lowerBound].utf8.count
        try view.replaceUTF8Range(NSRange(location: offset, length: 2), withReplacement: Data("  ".utf8),
                                  expectedRevision: view.revision, resultingRevision: view.revision + 1)
        // Force the native paint path even when the test window is offscreen.
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let hidden = try #require(source.range(of: "actor hidden"))
        #expect(view.style(atUTF8Position: UInt(source[..<hidden.lowerBound].utf8.count)) == 3)
    }
}
