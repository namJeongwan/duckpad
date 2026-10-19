import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct MinimapTests {
    private func fixture(_ text: String) throws -> (DPScintillaEditorView, NSWindow, NSView) {
        _ = NSApplication.shared
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.isWordWrapEnabled = false
        view.isMinimapVisible = true
        view.minimapNavigationLabel = "Minimap"
        try view.loadUTF8(Data(text.utf8), revision: 1)
        view.layoutSubtreeIfNeeded()
        let map = try #require(view.value(forKey: "minimap") as? NSView)
        return (view, window, map)
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(260)) }
    private func number(_ view: NSView, _ key: String) -> Int { (view.value(forKey: key) as? NSNumber)?.intValue ?? -1 }
    private func viewport(_ map: NSView) -> NSRect { (map.value(forKey: "viewportRect") as? NSValue)?.rectValue ?? .zero }

    @Test func minimapCachesCodeAndScrollKeepsSelectionAndUndo() async throws {
        let text = (0..<2000).map { "    let value\($0) = \($0) // sample" }.joined(separator: "\n")
        let (view, window, map) = try fixture(text)
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 8, length: 5))
        try await settle()
        #expect(!map.isHidden)
        #expect(map.frame.width == 72)
        #expect(number(map, "sampledByteCount") > 0)
        #expect(number(map, "sampledByteCount") <= 800 * 256)
        #expect(view.editorRightPadding == 8)
        let builds = number(map, "imageBuildCount")
        let before = viewport(map)
        let reads = view.snapshotReadCount
        let caret = view.caretUTF8Position, anchor = view.anchorUTF8Position
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            let point = map.convert(NSPoint(x: map.bounds.midX, y: y), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        map.mouseDown(with: try event(.leftMouseDown, y: 240))
        map.mouseDragged(with: try event(.leftMouseDragged, y: 300))
        map.mouseUp(with: try event(.leftMouseUp, y: 300))
        try await settle()
        #expect(view.firstVisibleLine > 100)
        #expect(viewport(map).minY > before.minY)
        // Moving beyond the cached window fetches consecutive nearby lines.
        #expect(number(map, "imageBuildCount") > builds)
        #expect(number(map, "sampledByteCount") <= 800 * 256)
        let cached = number(map, "imageBuildCount")
        _ = map.accessibilityPerformIncrement()
        try await settle()
        #expect(number(map, "imageBuildCount") == cached)
        #expect(view.snapshotReadCount == reads)
        #expect(view.caretUTF8Position == caret && view.anchorUTF8Position == anchor)
        #expect(view.revision == 1)
        #expect(!view.canUndo)
    }

    @Test func fixedScaleDoesNotSkipLinesAndThumbPressDoesNotJump() async throws {
        let (view, window, map) = try fixture(String(repeating: "let apple = 1\n", count: 2000))
        defer { view.invalidate(); window.contentView = nil; window.close() }
        try await settle()
        // At four points per line, a 400-point pane caches 100 visible lines
        // plus overscan, rather than sampling all 2,000 lines.
        #expect(number(map, "sampledByteCount") > 100 * 13)
        #expect(number(map, "sampledByteCount") < 210 * 13)
        #expect(viewport(map).height > 40)
        let initialHeight = viewport(map).height
        let rect = viewport(map)
        let point = map.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let first = view.firstVisibleLine
        map.mouseDown(with: event)
        #expect(view.firstVisibleLine == first)
        map.mouseUp(with: event)
        for _ in 0..<20 { _ = map.accessibilityPerformIncrement() }
        try await settle()
        #expect(number(map, "mapTop") > 0)
        #expect(abs(viewport(map).height - initialHeight) < 1)
        #expect(!view.canUndo)
    }

    @Test func overviewMarkersAndMinimapShareMatchLines() async throws {
        let (view, window, map) = try fixture("apple orange apple\norange\napricot\n")
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
        try await settle()
        #expect((map.value(forKey: "markerLines") as? IndexSet) == IndexSet([0, 2]))
        #expect(view.searchOverviewPositions.count == 3)
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: 19, length: 6))], revision: 1))
        #expect((map.value(forKey: "markerLines") as? IndexSet) == IndexSet([1]))
        view.clearSearchHighlights()
        #expect((map.value(forKey: "markerLines") as? IndexSet) == IndexSet([0, 2]))
    }

    @Test func viewportTintCompositesOverCodeInBothPalettes() async throws {
        let (view, window, map) = try fixture(String(repeating: "let apple = 1\n", count: 100))
        defer { view.invalidate(); window.contentView = nil; window.close() }
        for palette: DPScintillaPalette in [.light, .dark] {
            view.apply(palette)
            try await settle()
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(map.bounds.width), pixelsHigh: Int(map.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            map.draw(map.bounds)
            NSGraphicsContext.restoreGraphicsState()
            // Tint over an opaque editor surface must never erase that surface
            // (or the code drawn on it) with a translucent replacement pixel.
            let minimumAlpha = (1..<Int(map.bounds.height) - 1).compactMap {
                bitmap.colorAt(x: Int(map.bounds.midX), y: $0)?.alphaComponent
            }.min() ?? 0
            #expect(minimumAlpha > 0.99)
        }
    }

    @Test func narrowPanesAndDisabledPreferenceRestoreEditorWidth() async throws {
        let (view, window, map) = try fixture("hello world")
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.configureTextLayout(withLeftPadding: 3, rightPadding: 12, lineSpacing: 4)
        view.layoutSubtreeIfNeeded()
        #expect(!map.isHidden)
        view.isMinimapVisible = false
        view.layoutSubtreeIfNeeded()
        #expect(map.isHidden)
        #expect(view.editorRightPadding == 12)
        view.isMinimapVisible = true
        window.setContentSize(NSSize(width: 350, height: 400))
        view.layoutSubtreeIfNeeded()
        #expect(map.isHidden)
        window.setContentSize(NSSize(width: 800, height: 400))
        view.layoutSubtreeIfNeeded()
        try await settle()
        #expect(!map.isHidden)
        #expect(view.editorRightPadding == 12)
    }

    @Test func editsInvalidateImageAndEnormousLinesStayBounded() async throws {
        let (view, window, map) = try fixture(String(repeating: "x", count: 2_000_000))
        defer { view.invalidate(); window.contentView = nil; window.close() }
        try await settle()
        #expect(number(map, "sampledByteCount") <= 256)
        let builds = number(map, "imageBuildCount")
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 1))
        view.insertCommittedText("y")
        try await settle()
        #expect(number(map, "imageBuildCount") > builds)
        #expect(number(map, "sampledByteCount") <= 256)
    }

    @Test func binarySwitchHidesMinimapAndPendingTeardownIsSafe() async throws {
        let (view, window, map) = try fixture("let x = 1")
        let binary = try await DPScintillaBinaryDocument.begin(data: Data([0, 0xFF, 0x80]))
        view.load(binary, revision: 2)
        view.layoutSubtreeIfNeeded()
        #expect(map.isHidden)
        view.invalidate()
        window.contentView = nil
        window.close()
        try await settle()
    }
}
