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
    @Test(arguments: [false, true])
    func fiveMiBFileOpenTypingBackspaceAndUndo(singleLine: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unit = singleLine ? "abcdefghijklmnopqrst" : "abcdefghijklmnopqrs\n"
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
        let midpoint = text.utf8.count / 2
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
        restored.insert("x", at: restored.index(restored.startIndex, offsetBy: midpoint))
        #expect(String(decoding: native.contentUTF8, as: UTF8.self) == restored)
        native.redo()
        #expect(String(decoding: native.contentUTF8, as: UTF8.self) == text)
        #expect(try Data(contentsOf: file) == Data(text.utf8))
        print("5MiB singleLine=\(singleLine): open=\(openTime), typing median=\(typing.sorted()[5]), backspace median=\(deletion.sorted()[5])")
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
