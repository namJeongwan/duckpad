import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
struct CaretLineRenderingTests {
    @Test @MainActor func currentLineUsesThePaletteAcrossTextAndRemainder() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        defer { view.invalidate(); window.close() }
        let lines = ["@startuml", "Alice -> Bob: " + String(repeating: "long text ", count: 10),
                     "Bob --> Alice: short", "Alice -> Bob: " + String(repeating: "medium ", count: 7), "@enduml"]
        try view.loadUTF8(Data(lines.joined(separator: "\n").utf8), revision: 0)
        view.isWordWrapEnabled = false
        #expect(view.applyLexerNamed("plantuml", keywords: [], tabWidth: 4, useTabs: false,
                                    folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        view.layoutSubtreeIfNeeded()
        view.focusEditor()
        // Test activation without opening a window or depending on another app's focus.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for line in [1, 2, 3, 1] {
            let position = lines.prefix(line).map { $0.utf8.count + 1 }.reduce(0, +) + 3
            view.setPrimarySelectionUTF8Range(NSRange(location: position, length: 0))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // The first pixel row avoids glyphs; x=100 is inside text, x=850 is after
            // the short line's EOL. Both must receive the same current-row background.
            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            for row in 0..<lines.count {
                for x in [100, 850] {
                    let color = try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale),
                        y: Int(CGFloat(row * 19 + 1) * scale)))
                    let expected = row == line ? [237, 237, 238] : [250, 250, 250]
                    for (component, byte) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                        #expect(abs(component * 255 - CGFloat(byte)) < 2)
                    }
                }
            }
            #expect(view.caretLine == line)
            #expect(view.caretUTF8Position == view.anchorUTF8Position)
        }
    }
}
