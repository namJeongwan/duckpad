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
        view.clearSearchHighlights()
        #expect(!clone.isSearchHighlighted(atUTF8Position: 14))
    }

}
