import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct SearchHighlightTests {
    private func fixture(_ text: String) async throws -> (DuckpadWindowController, ScintillaEditorAdapter, EditorBufferDescriptor) {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: adapter,
                                                editorView: adapter.view, searchUseCase: search,
                                                automaticallyStarts: false)
        controller.start()
        await controller.waitForStartup()
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: text))
        adapter.display(buffer)
        controller.performShowFind()
        return (controller, adapter, buffer)
    }

    @Test func findNextHighlightsEveryMatchAndKeepsHighlightsDuringNavigation() async throws {
        let text = "return 한글 return\nreturnValue return"
        let (controller, adapter, buffer) = try await fixture(text)
        defer { controller.close() }
        let view = try #require(adapter.activeScintillaView)
        controller.searchPanel.show(replace: false, selectedText: "return")
        controller.performFindNext()
        for _ in 0..<100 {
            if view.isSearchHighlighted(atUTF8Position: 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bytes = Array(text.utf8)
        let pattern = Array("return".utf8)
        let offsets = (0...(bytes.count - pattern.count)).filter { Array(bytes[$0..<($0 + pattern.count)]) == pattern }
        #expect(offsets.count == 4)
        #expect(view.searchOverviewPositions.count == 4)
        for offset in offsets {
            #expect(view.isSearchHighlighted(atUTF8Position: UInt(offset)))
            #expect(view.isSearchHighlighted(atUTF8Position: UInt(offset + 5)))
        }
        #expect(!view.isSearchHighlighted(atUTF8Position: 6))
        let first = adapter.activeSelectionUTF8Range()
        controller.performFindNext()
        for _ in 0..<100 {
            if adapter.activeSelectionUTF8Range() != first { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.activeSelectionUTF8Range() != first)
        #expect(offsets.allSatisfy { view.isSearchHighlighted(atUTF8Position: UInt($0)) })
        #expect(adapter.snapshot(for: buffer.bufferID)?.text == text)
        #expect(view.revision == buffer.revision)
        #expect(!view.canUndo)
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_HIGHLIGHT_SNAPSHOTS"] {
            controller.showAndFocus()
            let window = try #require(controller.window)
            window.setContentSize(NSSize(width: 760, height: 260))
            controller.searchPanel.window?.orderOut(nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                view.apply(appearance == .darkAqua ? .dark : .light)
                window.makeKeyAndOrderFront(nil)
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                     URL(fileURLWithPath: directory).appendingPathComponent("matches-\(appearance.rawValue).png").path]
                try capture.run()
                capture.waitUntilExit()
                #expect(capture.terminationStatus == 0)
            }
        }
        controller.performCloseFindPanel()
        #expect(view.searchOverviewPositions.isEmpty)
        #expect(offsets.allSatisfy { !view.isSearchHighlighted(atUTF8Position: UInt($0)) })
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func selectionCheckboxPreservesTheRangeAndHighlightsOnlyMatchesInsideIt() async throws {
        let (controller, adapter, _) = try await fixture("return a return b return")
        defer { controller.close() }
        let view = try #require(adapter.activeScintillaView)
        let original = SearchUTF8Range(location: 0, length: 15)
        view.setPrimarySelectionUTF8Range(NSRange(location: original.location, length: original.length))
        let panel = controller.searchPanel
        panel.show(replace: false, selectedText: "return")
        let field = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.find" } as? NSSearchField)
        let selection = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.selection" } as? NSButton)
        if let action = field.action { field.sendAction(action, to: field.target) }
        selection.state = .on
        selection.sendAction(selection.action, to: selection.target)
        for _ in 0..<100 {
            if view.isSearchHighlighted(atUTF8Position: 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(adapter.activeSelectionUTF8Range() == original)
        #expect(view.isSearchHighlighted(atUTF8Position: 0))
        #expect(view.isSearchHighlighted(atUTF8Position: 9))
        #expect(!view.isSearchHighlighted(atUTF8Position: 18))
        for _ in 0..<3 {
            let previous = adapter.activeSelectionUTF8Range()
            controller.performFindNext()
            for _ in 0..<100 {
                if adapter.activeSelectionUTF8Range() != previous { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect((adapter.activeSelectionUTF8Range()?.upperBound ?? Int.max) <= original.upperBound)
        }
    }

    @Test func optionsEmptyQueryAndEditsRefreshTheActualNativeDecorations() async throws {
        let (controller, adapter, buffer) = try await fixture("return Return returnValue")
        defer { controller.close() }
        let panel = controller.searchPanel
        let view = try #require(adapter.activeScintillaView)
        panel.show(replace: false, selectedText: "return")
        for _ in 0..<100 {
            if view.isSearchHighlighted(atUTF8Position: 7) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let controls = descendants(panel).compactMap { $0 as? NSButton }
        for identifier in ["duckpad.search.match-case", "duckpad.search.whole-word"] {
            let option = try #require(controls.first { $0.accessibilityIdentifier() == identifier })
            option.state = .on
            option.sendAction(option.action, to: option.target)
        }
        for _ in 0..<100 {
            if view.isSearchHighlighted(atUTF8Position: 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.isSearchHighlighted(atUTF8Position: 0))
        #expect(!view.isSearchHighlighted(atUTF8Position: 7))
        #expect(!view.isSearchHighlighted(atUTF8Position: 14))
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        view.beginGroupedUndo()
        view.insertCommittedText("other")
        view.endGroupedUndo()
        #expect(!view.isSearchHighlighted(atUTF8Position: 0))
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isSearchHighlighted(atUTF8Position: 0))
        view.undo()
        #expect(adapter.snapshot(for: buffer.bufferID)?.text == "return Return returnValue")
        for _ in 0..<100 {
            if view.isSearchHighlighted(atUTF8Position: 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.isSearchHighlighted(atUTF8Position: 0))
        let field = try #require(descendants(panel).first { $0.accessibilityIdentifier() == "duckpad.search.find" } as? NSSearchField)
        field.stringValue = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(!view.isSearchHighlighted(atUTF8Position: 0))
    }

    @Test func nativeHighlightsRejectStaleOrSplitUTF8RangesAndPreserveMultipleSelections() throws {
        let view = DPScintillaEditorView(frame: .zero)
        try view.loadUTF8(Data("한글 return return".utf8), revision: 7)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        #expect(view.addSelectionUTF8Range(NSRange(location: 7, length: 6)))
        let caret = view.caretUTF8Position
        let anchor = view.anchorUTF8Position
        let reads = view.snapshotReadCount
        let ranges = [NSValue(range: NSRange(location: 7, length: 6)), NSValue(range: NSRange(location: 14, length: 6))]
        #expect(view.setSearchHighlights(ranges, revision: 7))
        #expect(view.isSearchHighlighted(atUTF8Position: 7))
        #expect(!view.setSearchHighlights([NSValue(range: NSRange(location: 1, length: 2))], revision: 7))
        #expect(!view.setSearchHighlights(ranges, revision: 6))
        #expect(view.selectionCount == 2)
        #expect(view.caretUTF8Position == caret)
        #expect(view.anchorUTF8Position == anchor)
        #expect(view.snapshotReadCount == reads)
        #expect(!view.canUndo)
        let clone = DPScintillaEditorView(frame: .zero)
        clone.shareDocument(with: view)
        clone.apply(.dark)
        #expect(clone.isSearchHighlighted(atUTF8Position: 14))
        #expect(clone.searchOverviewPositions == view.searchOverviewPositions)
        view.clearSearchHighlights()
        #expect(!clone.isSearchHighlighted(atUTF8Position: 14))
        #expect(clone.searchOverviewPositions.isEmpty)
    }

    @Test func overviewUsesFullScrollbarWidthAndOnlyCapturesMarkerHits() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.isWordWrapEnabled = false
        let text = (0..<101).map { "line \($0)" }.joined(separator: "\n")
        try view.loadUTF8(Data(text.utf8), revision: 1)
        let offsets = [0, 50, 100].map { line in
            (0..<line).reduce(0) { $0 + "line \($1)\n".utf8.count }
        }
        #expect(view.setSearchHighlights(offsets.map { NSValue(range: NSRange(location: $0, length: 4)) }, revision: 1))
        let positions = view.searchOverviewPositions.map(\.doubleValue)
        #expect(positions.count == 3)
        #expect(positions[0] >= 0 && positions[2] <= 1)
        #expect(abs((positions[1] - positions[0]) - (positions[2] - positions[1])) < 0.001)
        view.layoutSubtreeIfNeeded()
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        #expect(!overlay.isHidden)
        #expect(overlay.frame.maxX <= view.bounds.maxX)
        #expect(overlay.frame.height > 0)
        #expect(overlay.frame.width >= 12)
        #expect(overlay.hitTest(NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)) === overlay)
        #expect(overlay.hitTest(NSPoint(x: overlay.frame.midX, y: overlay.frame.minY + overlay.frame.height * 0.25)) == nil)
        let snapshotReads = view.snapshotReadCount
        view.setFrameSize(NSSize(width: 400, height: 500))
        view.layoutSubtreeIfNeeded()
        #expect(overlay.frame.height > 240)
        #expect(view.snapshotReadCount == snapshotReads)
        #expect(!view.canUndo)
        view.insertCommittedText("edit")
        #expect(view.searchOverviewPositions.isEmpty)
        #expect(overlay.isHidden)
    }

    @Test func denseOverviewMarkersStayTranslucentInBothThemes() throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        defer { view.invalidate() }
        try view.loadUTF8(Data("MATCH".utf8), revision: 1)
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: 0, length: 5))], revision: 1))
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        overlay.frame = NSRect(x: 0, y: 0, width: 16, height: 100)
        func alpha(positions: [Double]) throws -> CGFloat {
            overlay.setValue(positions.map { NSNumber(value: $0) }, forKey: "positions")
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16,
                pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.clear.setFill()
            overlay.bounds.fill(using: .copy)
            overlay.draw(overlay.bounds)
            return (0..<100).compactMap { bitmap.colorAt(x: 8, y: $0)?.alphaComponent }.max() ?? 0
        }
        for palette: DPScintillaPalette in [.light, .dark] {
            view.apply(palette)
            let isolated = try alpha(positions: [0.5])
            let dense = try alpha(positions: (0..<200).map { 0.49 + Double($0) / 10000 })
            #expect(isolated > 0.2 && isolated < 0.5)
            #expect(abs(dense - isolated) < 0.01)
        }
    }

    @Test func overviewTracksCollapsedLinesWithoutLayingOutTheLastLine() throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        defer { view.invalidate() }
        view.isWordWrapEnabled = false
        let source = "int main() {\n  int x = 1;\n  return x;\n}\nMATCH\ntail"
        try view.loadUTF8(Data(source.utf8), revision: 1)
        #expect(view.applyLexerNamed("cpp", keywords: ["int return"], tabWidth: 4, useTabs: false,
                                    folding: true, braceMatching: false, maximumStyleBytes: 1_000_000))
        let offset = try #require(source.range(of: "MATCH")).lowerBound
        let bytes = source[..<offset].utf8.count
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: bytes, length: 5))], revision: 1))
        let before = try #require(view.searchOverviewPositions.first).doubleValue
        let reads = view.snapshotReadCount
        view.toggleFold(atLine: 0)
        #expect(!view.isFoldExpanded(atLine: 0))
        #expect(try #require(view.searchOverviewPositions.first).doubleValue < before)
        view.toggleFold(atLine: 0)
        #expect(try #require(view.searchOverviewPositions.first).doubleValue == before)
        #expect(view.snapshotReadCount == reads)
        #expect(!view.canUndo)
    }

    @Test func overviewTracksIdleWrappingAndResize() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        let source = String(repeating: "word ", count: 80) + "\nMATCH\ntail"
        try view.loadUTF8(Data(source.utf8), revision: 1)
        view.isWordWrapEnabled = false
        let offset = source.utf8.count - "MATCH\ntail".utf8.count
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: offset, length: 5))], revision: 1))
        let unwrapped = try #require(view.searchOverviewPositions.first).doubleValue
        window.orderFront(nil)
        view.isWordWrapEnabled = true
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if (view.searchOverviewPositions.first?.doubleValue ?? 0) > unwrapped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let wrapped = try #require(view.searchOverviewPositions.first).doubleValue
        #expect(wrapped > unwrapped)
        window.setContentSize(NSSize(width: 220, height: 300))
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if (view.searchOverviewPositions.first?.doubleValue ?? 0) > wrapped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try #require(view.searchOverviewPositions.first).doubleValue > wrapped)
    }

    @Test func matchesInsideOneWrappedLineHaveDistinctTicksAndClickExactMatch() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        let prefix = String(repeating: "긴 JSON 문자열 ", count: 40)
        let middle = String(repeating: "wrapped text ", count: 80)
        let source = prefix + "MATCH " + middle + "MATCH tail\nMATCH next line"
        let offsets = [prefix.utf8.count, prefix.utf8.count + 6 + middle.utf8.count, prefix.utf8.count + 6 + middle.utf8.count + 11]
        try view.loadUTF8(Data(source.utf8), revision: 1)
        view.isWordWrapEnabled = true
        window.orderFront(nil)
        #expect(view.setSearchHighlights(offsets.map { NSValue(range: NSRange(location: $0, length: 5)) }, revision: 1))
        #expect(view.searchOverviewPositions.map(\.doubleValue) == view.searchOverviewPositions.map(\.doubleValue).sorted())
        for _ in 0..<30 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            #expect(view.searchOverviewPositions.map(\.doubleValue) == view.searchOverviewPositions.map(\.doubleValue).sorted())
            try await Task.sleep(for: .milliseconds(10))
        }
        let positions = view.searchOverviewPositions.map(\.doubleValue)
        #expect(positions.count == 3)
        guard positions.count == 3 else { return }
        #expect(positions[0] > 0.1 && positions[0] < 0.8)
        #expect(positions[1] > positions[0] + 0.1)
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX,
            y: positions[1] * (overlay.bounds.height - 3) + 1.5), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: event)
        #expect(view.caretUTF8Position == offsets[1])
        #expect(view.firstVisibleLine > 0)
        #expect(!view.canUndo)
        view.displayIfNeeded()
        let scroller = try #require(descendants(view).compactMap { $0 as? NSScroller }.first { $0.frame.height > $0.frame.width })
        let knob = overlay.convert(scroller.rect(for: .knob), from: scroller)
        let tickY = (try #require(view.searchOverviewPositions.dropFirst().first)).doubleValue * (overlay.bounds.height - 3) + 1.5
        #expect(tickY >= knob.minY - 2 && tickY <= knob.maxY + 2)
        for width: CGFloat in [600, 240] {
            window.setContentSize(NSSize(width: width, height: 240))
            for _ in 0..<15 {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let current = view.searchOverviewPositions.map(\.doubleValue)
                #expect(current == current.sorted())
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func manyMatchesInOneWrappedCloneReuseLayout() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = DPScintillaEditorView(frame: .zero)
        let clone = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        window.contentView = clone
        defer { clone.invalidate(); source.invalidate(); window.contentView = nil; window.close() }
        source.isWordWrapEnabled = false
        let chunk = "text MATCH more "
        try source.loadUTF8(Data(String(repeating: chunk, count: 2000).utf8), revision: 1)
        clone.shareDocument(with: source)
        clone.isWordWrapEnabled = true
        window.orderFront(nil)
        for _ in 0..<20 {
            clone.layoutSubtreeIfNeeded()
            clone.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let matches = (0..<2000).map { NSValue(range: NSRange(location: $0 * chunk.utf8.count + 5, length: 5)) }
        let start = ContinuousClock.now
        #expect(clone.setSearchHighlights(matches, revision: 1))
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(clone.searchOverviewPositions.count == 2000)
        let positions = clone.searchOverviewPositions.map(\.doubleValue)
        #expect(positions == positions.sorted())
        #expect(try #require(positions.last) > (try #require(positions.first)) + 0.5)
        #expect(source.searchOverviewPositions.count == 2000)
        #expect(!clone.canUndo)
    }

    @Test func clickingSearchOverviewRevealsTheMatchingLine() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.isWordWrapEnabled = false
        let source = (0..<200).map { "Line \($0)" }.joined(separator: "\n")
        try view.loadUTF8(Data(source.utf8), revision: 1)
        let range = try #require(source.range(of: "Line 150"))
        let offset = source[..<range.lowerBound].utf8.count
        #expect(view.setSearchHighlights([NSValue(range: NSRange(location: offset, length: 8))], revision: 1))
        view.layoutSubtreeIfNeeded()
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        let fraction = try #require(view.searchOverviewPositions.first).doubleValue
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX, y: fraction * (overlay.bounds.height - 3) + 1.5), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: event)
        #expect(view.caretUTF8Position == offset)
        #expect(view.isSearchHighlighted(atUTF8Position: UInt(offset)))
        #expect(!view.canUndo)
    }

    @Test func denseSearchTicksDoNotBlockNativeScrollbarThumb() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = view
        defer { view.invalidate(); window.contentView = nil; window.close() }
        view.isWordWrapEnabled = false
        try view.loadUTF8(Data(String(repeating: "MATCH\n", count: 500).utf8), revision: 1)
        #expect(view.setSearchHighlights((0..<500).map { NSValue(range: NSRange(location: $0 * 6, length: 5)) }, revision: 1))
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let overlay = try #require(descendants(view).first { $0.accessibilityIdentifier() == "duckpad.search.overview" })
        let scroller = try #require(descendants(view).compactMap { $0 as? NSScroller }.first { $0.frame.height > $0.frame.width })
        let knob = scroller.rect(for: .knob)
        #expect(knob.height > 0)
        let point = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: overlay.superview)
        #expect(overlay.hitTest(point) == nil)
        let tickPoint = NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        #expect(overlay.hitTest(tickPoint) === overlay)
    }

}
