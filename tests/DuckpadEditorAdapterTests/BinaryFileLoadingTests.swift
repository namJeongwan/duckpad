import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
@MainActor
struct BinaryFileLoadingTests {
    @Test func contentAndProgressAppearBeforeLoadingCompletes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0x41, count: 4 * 1_024 * 1_024)
        data[0] = 0
        for offset in stride(from: 63, to: data.count, by: 64) { data[offset] = 0x0A }
        try data.write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
            editorView: editor.view, fileUseCase: files, automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        _ = await workspace.start()
        let render = files.onLoadingProgress
        var percentages: [Int] = []
        var sawPartialContent = false
        files.onLoadingProgress = {
            render?()
            guard let progress = files.loadingProgress else { return }
            percentages.append(progress.percent)
            #expect(controller.statusBar.lengthLabel.stringValue ==
                L10n.text("Loading: %1$@%%", L10n.argument(progress.percent)))
            if progress.loadedByteCount > 0, progress.loadedByteCount < data.count,
               let context = workspace.activeFileContext(), context.binding?.canonicalPath == url.path,
               let native = editor.activeScintillaView {
                #expect(native.documentByteLength == UInt(progress.loadedByteCount))
                #expect(!native.isInputEnabled)
                #expect(!editor.hasBinaryContent(for: context.buffer.bufferID))
                if !sawPartialContent {
                    native.zoomLevel = 3
                    native.restoreCaretUTF8Position(0, anchorPosition: 0,
                        firstVisibleLine: 200, horizontalScrollOffset: 0, wordWrapEnabled: false)
                }
                sawPartialContent = true
            }
        }
        guard case .opened = await files.open(url) else { Issue.record("File did not open"); return }
        #expect(sawPartialContent)
        #expect(percentages.first == 0)
        #expect(percentages.last == 100)
        #expect(percentages == percentages.sorted())
        #expect(files.loadingProgress == nil)
        #expect(!controller.statusBar.lengthLabel.stringValue.contains("%"))
        #expect(editor.activeScintillaView?.contentUTF8 == data)
        #expect(editor.activeScintillaView?.caretUTF8Position == 0)
        #expect(editor.activeScintillaView?.anchorUTF8Position == 0)
        #expect(editor.activeScintillaView?.firstVisibleLine == 200)
        #expect(editor.activeScintillaView?.zoomLevel == 3)
        #expect(editor.recoveryCapture(for: try #require(workspace.snapshot().activeBuffer).bufferID)?.baseUTF8.isEmpty == true)
    }

    @Test func sidebarShowsLoadingBeforeDiskReadAndClearsItOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = LocalWorkspaceRootStore(archiveURL: directory.appendingPathComponent("roots.json"))
        let root = try await roots.addRoot(directory)
        let browser = WorkspaceBrowserUseCase(store: roots)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore())
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
            editorView: editor.view, fileUseCase: files, workspaceBrowserUseCase: browser,
            automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        _ = await workspace.start()
        _ = await browser.start()
        controller.routeOpenWorkspaceEntry(WorkspaceBrowserEntry(rootID: root.id,
            relativePath: "missing.bin", name: "missing.bin", kind: .file))
        #expect(controller.statusBar.lengthLabel.stringValue == L10n.text("Loading: %1$@%%", L10n.argument(0)))
        for _ in 0..<1_000 where controller.statusBar.lengthLabel.stringValue.contains("%") {
            await Task.yield()
        }
        #expect(!controller.statusBar.lengthLabel.stringValue.contains("%"))
        #expect(files.loadingProgress == nil)
    }

    @Test func retiringAPartiallyLoadedBufferStopsFurtherAppends() async throws {
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let data = Data(repeating: 0x0A, count: 2 * 1_024 * 1_024)
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let install = try await editor.prepareBinary(data)
        install(buffer)
        editor.display(buffer)
        var retired = false
        do {
            try await editor.finishBinaryLoad(for: buffer) { loaded, total in
                if loaded < total, !retired {
                    retired = true
                    editor.retire(bufferID: buffer.bufferID)
                }
            }
            Issue.record("Retired load completed")
        } catch is CancellationError { }
        #expect(retired)
        #expect(!editor.hasBinaryContent(for: buffer.bufferID))
        #expect(editor.recoveryCapture(for: buffer.bufferID) == nil)
    }
}
