import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Testing
@testable import DuckpadEditorAdapter

@Suite(.serialized) @MainActor
struct ProjectSearchFairnessTests {
    @Test(arguments: [false, true])
    func nonmatchingLargeRootCannotConsumeTheBudgetForAllLaterRoots(byteLimited: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-search-fairness-" + UUID().uuidString)
        let large = root.appendingPathComponent("first-larger-project"), last = root.appendingPathComponent("last")
        for directory in [large, last] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<6 { try Data(repeating: 97, count: 1024).write(to: large.appendingPathComponent("file\(number).txt")) }
        try Data("https://dp-stats.hongyoungjun.com\n".utf8).write(to: last.appendingPathComponent("config.txt"))
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { workspace.onChange = nil; editor.invalidate() }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
        let limits = FolderSearchLimits(maximumFiles: byteLimited ? 100 : 5,
            maximumTotalBytes: byteLimited ? 4096 : 1024 * 1024)
        let folders = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            limits: limits, backend: RipgrepFolderSearchBackend(executable: helper))
        let native = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let useCase = ProjectSearchUseCase(workspace: workspace, search: native, folderSearch: folders)
        let roots = [large, last].map { WorkspaceRoot(canonicalPath: $0.path, displayName: $0.lastPathComponent) }
        let value = try await useCase.find(.init(pattern: "hongyoung"), scope: .all, roots: roots, folder: nil)
        #expect(value.folder.matchCount == 1)
        #expect(value.folder.documents.first?.path == last.appendingPathComponent("config.txt").path)
        #expect(value.isTruncated)
        #expect(value.folder.searchedFileCount + value.open.searchedDocumentCount <= limits.maximumFiles)
        #expect(value.folder.searchedByteCount + value.open.searchedByteCount <= limits.maximumTotalBytes)
    }
}
