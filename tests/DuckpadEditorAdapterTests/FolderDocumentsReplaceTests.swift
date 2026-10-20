import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Testing
@testable import DuckpadEditorAdapter

@Suite(.serialized) @MainActor
struct FolderDocumentsReplaceTests {
    private var folder: FolderSearchUseCase {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
        return FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            backend: RipgrepFolderSearchBackend(executable: executable))
    }
    @Test func folderReplacementStagesUnopenedFilesWithoutMovingCaretOrWritingDisk() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("duck 한글\r\n".utf8).write(to: first); try Data("duck 🦆\n".utf8).write(to: second)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { workspace.onChange = nil; editor.invalidate(); window.contentView = nil; window.close() }
        _ = await workspace.start()
        let original = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: original.bufferID, revision: original.revision, text: "original selection"))
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 9, length: 9))
        let selection = editor.activeSelectionUTF8Range()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let query = SearchQuery(pattern: "duck", replacement: "오리", options: .init(scope: .allOpenDocuments))
        let preview = try await folder.search(rootPath: root.path, query: query)
        let result = try await FolderDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: preview)
        #expect(result.replacementCount == 2)
        #expect(result.skippedDocumentCount == 0)
        #expect(workspace.snapshot().activeBuffer == original)
        #expect(editor.activeSelectionUTF8Range() == selection)
        #expect(try String(contentsOf: first, encoding: .utf8) == "duck 한글\r\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "duck 🦆\n")
        let tab = try #require(workspace.snapshot().tabs.first { $0.fullPath == first.path })
        #expect(tab.isDirty)
        #expect(editor.snapshot(for: tab.buffer.bufferID)?.text == "오리 한글\r\n")
        _ = await workspace.activate(tabID: tab.id)
        editor.activeScintillaView?.undo()
        #expect(editor.snapshot(for: tab.buffer.bufferID)?.text == "duck 한글\r\n")
        editor.activeScintillaView?.redo()
        #expect(editor.snapshot(for: tab.buffer.bufferID)?.text == "오리 한글\r\n")
        await files.releaseAllSecurityScopedAccess()
    }

    @Test func changedDiskAndDirtyOpenFilesAreSkippedAndUnrelatedBuffersStayIntact() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("changed.txt")
        try Data("duck".utf8).write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { workspace.onChange = nil; editor.invalidate() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let query = SearchQuery(pattern: "duck", replacement: "goose", options: .init(scope: .allOpenDocuments))
        let preview = try await folder.search(rootPath: root.path, query: query)
        try Data("duck changed outside".utf8).write(to: url)
        let skipped = try await FolderDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: preview)
        #expect(skipped.documents.first?.status == .changed)
        #expect(skipped.replacementCount == 0)
        #expect(workspace.snapshot().tabs.allSatisfy { $0.fullPath != url.path })
        _ = await files.open(url)
        editor.activeScintillaView?.insertCommittedText("local ")
        await workspace.waitForPendingPersistence()
        let before = try #require(editor.activeScintillaView?.contentUTF8)
        let latest = try await folder.search(rootPath: root.path, query: query)
        let dirty = try await FolderDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: latest)
        #expect(dirty.documents.first?.status == .changed)
        #expect(editor.activeScintillaView?.contentUTF8 == before)
        #expect(try String(contentsOf: url, encoding: .utf8) == "duck changed outside")
        await files.releaseAllSecurityScopedAccess()
    }
}
