import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

// Large-file rendering and visible-window sweeps own the process-wide AppKit
// loop. Run separately so they cannot starve unrelated idle-timer tests.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_LARGE_DOCUMENT_PROBE"] == "1"))
@MainActor
struct LargeDocumentResponsivenessTests {
    @Test(arguments: ["abcdefghijklmnopqrs\n", "abcdefghijklmnopqrst", "ㅁ", "한글🦆éאבג"])
    func fiveMiBFileOpenTypingBackspaceAndUndo(unit: String) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: unit, count: 5 * 1_024 * 1_024 / unit.utf8.count)
        let file = root.appendingPathComponent("five-mib.txt")
        try Data(text.utf8).write(to: file)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json")))
        let controller = DuckpadWindowController(
            workspace: workspace, editorAdapter: editor, editorView: editor.view,
            fileUseCase: files, automaticallyStarts: false
        )
        defer { controller.close(); editor.invalidate() }
        _ = await workspace.start()
        let begin = ContinuousClock.now
        guard case .opened = await files.open(file) else { Issue.record("File did not open"); return }
        let native = try #require(editor.activeScintillaView)
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let openTime = begin.duration(to: .now)
        let insertionIndex = text.index(text.startIndex, offsetBy: text.count / 2)
        let midpoint = text.utf8.distance(from: text.utf8.startIndex, to: insertionIndex)
        native.setPrimarySelectionUTF8Range(NSRange(location: midpoint, length: 0))
        native.focusEditor()
        let responder = try #require(window.firstResponder)
        let backspace = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
            isARepeat: true, keyCode: 51
        ))
        let reads = native.snapshotReadCount
        var typing: [Duration] = []
        var deletion: [Duration] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            native.insertCommittedText("x")
            window.contentView?.displayIfNeeded()
            typing.append(start.duration(to: .now))
            let deleteStart = ContinuousClock.now
            responder.keyDown(with: backspace)
            window.contentView?.displayIfNeeded()
            deletion.append(deleteStart.duration(to: .now))
            #expect(native.documentByteLength == text.utf8.count)
        }
        #expect(native.snapshotReadCount == reads)
        #expect(String(decoding: native.contentUTF8, as: UTF8.self) == text)
        native.undo()
        var restored = text
        restored.insert("x", at: insertionIndex)
        #expect(String(decoding: native.contentUTF8, as: UTF8.self) == restored)
        native.redo()
        #expect(String(decoding: native.contentUTF8, as: UTF8.self) == text)
        #expect(try Data(contentsOf: file) == Data(text.utf8))
        print("5MiB unit=\(String(reflecting: unit)): open=\(openTime), typing median=\(typing.sorted()[5]), backspace median=\(deletion.sorted()[5])")
    }

    @Test func mixedUnicodeAndTabsSurviveFontOptimizationAndUndo() throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let text = "\t한글🦆 é\nאבג\t🙂"
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text))
        editor.display(buffer)
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let native = try #require(editor.activeScintillaView)
        for palette in [EditorThemePalette.light, .dark] {
            editor.applyTheme(palette)
            native.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
            native.insertCommittedText("한🙂")
            #expect(String(decoding: native.contentUTF8, as: UTF8.self) == text + "한🙂")
            native.undo()
            #expect(String(decoding: native.contentUTF8, as: UTF8.self) == text)
        }
    }

    @Test func cachedUnicodePositionsMatchFreshLayoutAfterZoomAndThemeChanges() throws {
        _ = NSApplication.shared
        let text = String(repeating: "한글🦆éאבג", count: 30)
        func makeEditor() -> (ScintillaEditorAdapter, NSWindow) {
            let editor = ScintillaEditorAdapter()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.view
            let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text))
            editor.display(buffer)
            return (editor, window)
        }
        func positions(_ editor: ScintillaEditorAdapter, _ window: NSWindow) throws -> [CGFloat] {
            window.contentView?.layoutSubtreeIfNeeded()
            let native = try #require(editor.activeScintillaView)
            native.focusEditor()
            let input = try #require(window.firstResponder as? any NSTextInputClient)
            let origin = input.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil).minX
            // UTF-16 grapheme boundaries spanning several cached subdivisions.
            return text.indices.dropFirst().enumerated().filter { $0.offset % 7 == 0 }.map { _, index in
                let offset = index.utf16Offset(in: text)
                return input.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil).minX - origin
            }
        }
        let (warm, window) = makeEditor()
        defer { window.close(); warm.invalidate() }
        let original = try positions(warm, window)
        for zoom in [5, -2, 0] {
            for palette in [EditorThemePalette.light, .dark] {
                warm.applyTheme(palette)
                warm.activeScintillaView?.zoomLevel = zoom
                let measured = try positions(warm, window)
                let (fresh, freshWindow) = makeEditor()
                defer { freshWindow.close(); fresh.invalidate() }
                fresh.applyTheme(palette)
                fresh.activeScintillaView?.zoomLevel = zoom
                #expect(measured == (try positions(fresh, freshWindow)))
                if zoom != 0 { #expect(measured != original) }
            }
        }
    }

    @Test func fullControllerWithFourPanesSettlesDuringResizing() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace, editorAdapter: editor, editorView: editor.view,
            secondaryEditorView: editor.secondaryGroupView,
            additionalEditorViews: editor.additionalEditorGroupViews,
            editorGroupRouter: editor, automaticallyStarts: false
        )
        defer { controller.close(); editor.invalidate() }
        _ = await workspace.start()
        for _ in 0..<11 { _ = await workspace.addScratch() }
        let tabs = workspace.snapshot().tabs
        let surface = controller.editorGroupWorkspace
        surface.onAction?(.splitAdjacent(tabs[0].id, .primary, .primary, .right, .copy))
        surface.onAction?(.splitAdjacent(tabs[0].id, .primary, .primary, .down, .copy))
        surface.onAction?(.splitAdjacent(tabs[0].id, .primary, .secondary, .down, .copy))
        #expect(controller.editorGroupLayoutSnapshot.visibleGroups.count == 4)
        for group in [EditorGroupID.secondary, .tertiary, .quaternary] {
            for tab in tabs.dropFirst().prefix(5) { surface.onAction?(.clone(tab.id, .primary, group)) }
        }
        let window = try #require(controller.window)
        window.orderFront(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [641.5, 1200, 893, 642.5, 1199] {
                window.setContentSize(NSSize(width: width, height: 800))
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                let panes = EditorGroupID.allCases.compactMap { surface.pane(for: $0) }
                let generations = panes.map { $0.tabStrip.flowLayout.layoutGeneration }
                let frames = panes.map(\.frame)
                try await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(panes.map { $0.tabStrip.flowLayout.layoutGeneration } == generations)
                #expect(panes.map(\.frame) == frames)
                #expect(panes.allSatisfy { $0.tabStrip.viewportHeight == $0.tabStrip.contentHeight })
                #expect(panes.allSatisfy { $0.editorHostView.frame.height > 0 })
            }
        }
    }
}
