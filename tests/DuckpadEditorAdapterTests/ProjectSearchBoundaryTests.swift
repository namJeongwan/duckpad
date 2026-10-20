import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Testing
@testable import DuckpadEditorAdapter

private struct DiskScanBarrier: RegexEnginePort {
    let barrier: SearchScanBarrierRegexEngine
    func directionalMatch(pattern: String, utf8: Data, matchCase: Bool, dotMatchesNewline: Bool, restrictTo: SearchUTF8Range, backwards: Bool) throws(SearchFailure) -> RegexEngineMatch? {
        try ICURegexEngine().directionalMatch(pattern: pattern, utf8: utf8, matchCase: matchCase, dotMatchesNewline: dotMatchesNewline, restrictTo: restrictTo, backwards: backwards)
    }
    func matches(pattern: String, utf8: Data, matchCase: Bool, dotMatchesNewline: Bool, restrictTo: SearchUTF8Range?, maximumMatches: Int) throws(SearchFailure) -> [RegexEngineMatch] {
        let engine: any RegexEnginePort = utf8.range(of: Data("disk".utf8)) == nil ? ICURegexEngine() : barrier
        return try engine.matches(pattern: pattern, utf8: utf8, matchCase: matchCase, dotMatchesNewline: dotMatchesNewline, restrictTo: restrictTo, maximumMatches: maximumMatches)
    }
}

@Suite(.serialized) @MainActor
struct ProjectSearchBoundaryTests {
    @MainActor private final class Fixture {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding: EditorBindingUseCase
        init() { _ = NSApplication.shared; binding = EditorBindingUseCase(workspace: workspace, editor: editor); let binding = binding; workspace.onChange = { binding.render($0) } }
        func start(_ text: String) async { _ = await workspace.start(); install(text) }
        func install(_ text: String) {
            if let buffer = workspace.snapshot().activeBuffer { editor.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: text)) }
        }
        func dispose() { workspace.onChange = nil; editor.invalidate() }
        func project(limits: FolderSearchLimits = .init(), engine: any RegexEnginePort = ICURegexEngine()) -> ProjectSearchUseCase {
            .init(workspace: workspace, search: .init(workspace: workspace, editor: editor, regexEngine: engine),
                folderSearch: .init(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(), limits: limits))
        }
    }
    @Test func openDocumentsShareFileByteMatchAndMetadataBudgetsAndRetainEarlierTruncation() async throws {
        let f = Fixture(); defer { f.dispose() }; await f.start(String(repeating: "x", count: 200))
        _ = await f.workspace.addScratch(); f.install("needle")
        let one = try await f.project(limits: .init(maximumDocumentBytes: 100, maximumMatches: 1))
            .find(.init(pattern: "needle"), scope: .openDocuments, roots: [], folder: nil)
        #expect(one.open.matchCount == 1); #expect(one.isTruncated)
        let files = try await f.project(limits: .init(maximumFiles: 1)).find(.init(pattern: "needle"), scope: .all, roots: [], folder: nil)
        #expect(files.open.matchCount == 0); #expect(files.open.searchedDocumentCount == 1); #expect(files.isTruncated)
        let bytes = try await f.project(limits: .init(maximumTotalBytes: 1)).find(.init(pattern: "needle"), scope: .openDocuments, roots: [], folder: nil)
        #expect(bytes.open.searchedByteCount == 0); #expect(bytes.isTruncated)
        let metadata = try await f.project(limits: .init(maximumResultBytes: 250)).find(.init(pattern: "needle"), scope: .openDocuments, roots: [], folder: nil)
        #expect(metadata.open.matchCount == 0); #expect(metadata.isTruncated)
        #expect(SearchResultBudget.bytes(metadata.open) <= 250)
    }
    @Test func unavailableOpenCapturesAreIncompleteRatherThanSilentlyOmitted() async throws {
        let f = Fixture(); defer { f.dispose() }; await f.start("needle")
        f.editor.invalidate()
        let result = try await f.project().find(.init(pattern: "needle"), scope: .openDocuments, roots: [], folder: nil)
        #expect(result.open.matchCount == 0); #expect(result.isTruncated)
    }
    @Test func changingOpenTopologyDuringCaptureCancelsInsteadOfFallingBackToDisk() async throws {
        let f = Fixture(); defer { f.dispose() }; await f.start("needle")
        let engine = SearchScanBarrierRegexEngine(base: ICURegexEngine())
        defer { engine.releaseScan() }
        let task = Task { try await f.project(engine: engine).find(.init(pattern: "needle", options: .init(mode: .regularExpression)), scope: .openDocuments, roots: [], folder: nil) }
        await engine.waitUntilScanEntered()
        _ = await f.workspace.addScratch()
        engine.releaseScan()
        do { _ = try await task.value; Issue.record("topology change must invalidate capture") }
        catch let error as SearchFailure { #expect(error == .cancelled) }
    }
    @Test func cancellingDiskPlanningKeepsCompletedOpenEditsSummaryAndUndo() async throws {
        let f = Fixture(); defer { f.dispose() }; await f.start("needle open")
        let original = try #require(f.workspace.snapshot().tabs.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("disk.txt"); try Data("needle disk".utf8).write(to: path)
        let engine = SearchScanBarrierRegexEngine(base: ICURegexEngine()); defer { engine.releaseScan() }
        let search = SearchWorkspaceUseCase(workspace: f.workspace, editor: f.editor, regexEngine: DiskScanBarrier(barrier: engine))
        let files = FileDocumentUseCase(workspace: f.workspace, editor: f.editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        let query = SearchQuery(pattern: "needle", replacement: "goose", options: .init(mode: .regularExpression, scope: .allOpenDocuments))
        let preview = try await ProjectSearchUseCase(workspace: f.workspace, search: search, folderSearch: .init(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine()))
            .find(query, scope: .all, roots: [.init(canonicalPath: root.path, displayName: "fixture")], folder: nil)
        let task = Task { try await ProjectDocumentsReplaceUseCase(workspace: f.workspace, files: files, search: search).replace(query, preview: preview) }
        await engine.waitUntilScanEntered()
        #expect(f.editor.snapshot(for: original.buffer.bufferID)?.text == "goose open")
        task.cancel(); engine.releaseScan()
        let result = try await task.value
        #expect(result.wasCancelled); #expect(result.replacementCount == 1)
        #expect(result.documents.contains { $0.title == "disk.txt" && $0.status == .cancelled })
        #expect(try String(contentsOf: path, encoding: .utf8) == "needle disk")
        _ = await f.workspace.activate(tabID: original.id)
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: original.buffer.bufferID)?.text == "needle open")
        await files.releaseAllSecurityScopedAccess()
    }
}
