import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Testing
@testable import DuckpadEditorAdapter

@Suite(.serialized) @MainActor
struct ProjectSearchScopeTests {
    private var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
    }
    @Test func fourScopesUseUnsavedBuffersAndDeduplicateNestedRegisteredRoots() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a"), nested = a.appendingPathComponent("nested"), b = root.appendingPathComponent("b")
        for dir in [nested, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let dirty = a.appendingPathComponent("dirty.txt"), closed = nested.appendingPathComponent("closed.txt"), outside = root.appendingPathComponent("outside.txt")
        for file in [dirty, closed, outside, b.appendingPathComponent("other.txt")] { try Data("needle\n".utf8).write(to: file) }
        try Data("nested/\n".utf8).write(to: a.appendingPathComponent(".gitignore"))
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { workspace.onChange = nil; editor.invalidate() }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        _ = await files.open(dirty)
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 0, length: 7))
        editor.activeScintillaView?.insertCommittedText("edited\n")
        await workspace.waitForPendingPersistence()
        _ = await files.open(outside)
        _ = await workspace.addScratch()
        editor.activeScintillaView?.insertCommittedText("needle unsaved\n")
        await workspace.waitForPendingPersistence()
        let disk = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(), backend: RipgrepFolderSearchBackend(executable: helper))
        let native = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let search = ProjectSearchUseCase(workspace: workspace, search: native, folderSearch: disk)
        let roots = [a, nested, b].map { WorkspaceRoot(canonicalPath: $0.path, displayName: $0.lastPathComponent) }
        let query = SearchQuery(pattern: "needle")
        let opened = try await search.find(query, scope: .openDocuments, roots: roots, folder: nil)
        #expect(opened.open.matchCount == 2); #expect(opened.folder.matchCount == 0)
        let all = try await search.find(query, scope: .all, roots: roots, folder: nil)
        #expect(all.open.matchCount == 2); #expect(all.folder.matchCount == 2); #expect(!all.isTruncated)
        #expect(Set(all.folder.documents.map(\.path)) == [closed.path, b.appendingPathComponent("other.txt").path])
        let registered = try await search.find(query, scope: .workspace, roots: roots, folder: nil)
        #expect(registered.open.matchCount == 0); #expect(registered.folder.matchCount == 2)
        // The selected folder applies its own ignore file, without the separately registered child root.
        let selected = try await search.find(query, scope: .folder, roots: roots, folder: a)
        #expect(selected.open.matchCount == 0); #expect(selected.folder.matchCount == 0)
        let edited = try await search.find(.init(pattern: "edited"), scope: .workspace, roots: roots, folder: nil)
        #expect(edited.open.matchCount == 1); #expect(edited.folder.matchCount == 0)
        #expect(try String(contentsOf: dirty, encoding: .utf8) == "needle\n")
        let masked = try await search.find(.init(pattern: "needle", fileMask: "other.txt"), scope: .all, roots: roots, folder: nil)
        #expect(masked.open.matchCount == 0); #expect(masked.folder.matchCount == 1)
        let limited = ProjectSearchUseCase(workspace: workspace, search: native,
            folderSearch: FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
                limits: .init(maximumFiles: 2), backend: RipgrepFolderSearchBackend(executable: helper)))
        let bounded = try await limited.find(query, scope: .workspace, roots: roots, folder: nil)
        #expect(bounded.folder.searchedFileCount == 1); #expect(bounded.folder.matchCount == 1); #expect(bounded.isTruncated)
        await files.releaseAllSecurityScopedAccess()
    }
}
