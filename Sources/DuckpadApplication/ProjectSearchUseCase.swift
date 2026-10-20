import DuckpadDomain
import Foundation

/// Combines registered roots and editor buffers under one bounded search budget.
@MainActor
public final class ProjectSearchUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private let search: SearchWorkspaceUseCase
    private let folderSearch: FolderSearchUseCase
    public init(workspace: ScratchWorkspaceUseCase, search: SearchWorkspaceUseCase, folderSearch: FolderSearchUseCase) {
        self.workspace = workspace; self.search = search; self.folderSearch = folderSearch
    }
    public func find(_ query: SearchQuery, scope: ProjectSearchScope, roots: [WorkspaceRoot], folder: URL?,
                     onProgress: (@Sendable (ProjectSearchResult) -> Void)? = nil) async throws -> ProjectSearchResult {
        let selected: [String]
        switch scope {
        case .openDocuments: selected = []
        case .all, .workspace: selected = roots.filter(\.isAvailable).map(\.canonicalPath)
        case .folder:
            guard let folder else { throw SearchFailure.invalidLimits }
            selected = [Self.canonical(folder.path)]
        }
        // More specific roots own their subtree, including their own ignore rules.
        let paths = Array(Set(selected.map(Self.canonical))).sorted { $0.count > $1.count }
        let snapshot = workspace.snapshot()
        let openPaths = Set(snapshot.tabs.compactMap { $0.fullPath.map(Self.canonical) })
        var seenPaths = Set<String>(), seenBuffers = Set<BufferID>(), ids = Set<TabID>()
        for tab in snapshot.tabs {
            let path = tab.fullPath.map(Self.canonical)
            let included = scope == .all || scope == .openDocuments || path.map { path in paths.contains { Self.isInside(path, root: $0) } } == true
            guard included, seenBuffers.insert(tab.buffer.bufferID).inserted else { continue }
            if let path, !seenPaths.insert(path).inserted { continue }
            ids.insert(tab.id)
        }
        func validateOpenBuffers() throws {
            let current = workspace.snapshot().tabs
            guard current.count == snapshot.tabs.count,
                  zip(current, snapshot.tabs).allSatisfy({ $0.id == $1.id && $0.buffer == $1.buffer && $0.fullPath == $1.fullPath }) else { throw SearchFailure.cancelled }
        }
        var query = query; query.options.scope = .allOpenDocuments
        let folderBase = SearchResultBudget.baseBytes + (scope == .folder ? paths.first?.utf8.count ?? 0 : 0)
        var openBudget = folderSearch.limits
        openBudget.maximumResultBytes = max(1, openBudget.maximumResultBytes - folderBase)
        let open = try await search.findAll(query, only: ids, budget: openBudget)
        try Task.checkCancellation(); try validateOpenBuffers()
        let unavailable = scope == .all || scope == .workspace ? roots.filter { !$0.isAvailable }.count : 0
        var documents: [FolderSearchDocumentResult] = []
        var files = 0, bytes = 0, skipped = unavailable
        var incomplete = unavailable > 0
        var completedRoots: [String] = []
        var remaining = folderSearch.limits
        remaining.maximumFiles -= open.searchedDocumentCount
        remaining.maximumMatches -= open.matchCount
        remaining.maximumResultBytes -= SearchResultBudget.bytes(open) + folderBase
        remaining.maximumTotalBytes -= open.searchedByteCount
        func result(_ active: FolderSearchResultSet? = nil, partial: Bool = false) -> ProjectSearchResult {
            .init(open: open, folder: .init(rootPath: scope == .folder ? paths.first ?? "" : "",
                documents: documents + (active?.documents ?? []),
                isTruncated: incomplete || partial || (active?.isTruncated ?? false),
                searchedFileCount: files + (active?.searchedFileCount ?? 0), skippedFileCount: skipped + (active?.skippedFileCount ?? 0),
                searchedByteCount: bytes + (active?.searchedByteCount ?? 0)), context: .init(scope: scope, roots: roots, folder: folder))
        }
        if !paths.isEmpty { onProgress?(result(partial: true)) }
        for path in paths {
            try Task.checkCancellation()
            guard !open.isTruncated, remaining.maximumMatches > 0, remaining.maximumResultBytes > 0,
                  remaining.maximumFiles > 0, remaining.maximumTotalBytes > 0 else { incomplete = true; break }
            // Freeze this cumulative value before crossing into a Sendable callback.
            let base = result()
            let value = try await folderSearch.search(rootPath: path, query: query,
                excluding: .init(paths: openPaths, directories: completedRoots), budget: remaining, onProgress: { active in
                    onProgress?(.init(open: base.open, folder: .init(rootPath: base.folder.rootPath,
                        documents: base.folder.documents + active.documents, isTruncated: true,
                        searchedFileCount: base.folder.searchedFileCount + active.searchedFileCount,
                        skippedFileCount: base.folder.skippedFileCount + active.skippedFileCount,
                        searchedByteCount: base.folder.searchedByteCount + active.searchedByteCount), context: base.context))
                })
            try Task.checkCancellation()
            documents += value.documents; files += value.searchedFileCount; bytes += value.searchedByteCount
            skipped += value.skippedFileCount; incomplete = incomplete || value.isTruncated
            remaining.maximumFiles -= value.searchedFileCount; remaining.maximumTotalBytes -= value.searchedByteCount
            remaining.maximumMatches -= value.matchCount; remaining.maximumResultBytes -= SearchResultBudget.bytes(value)
            completedRoots.append(path)
        }
        try Task.checkCancellation()
        try validateOpenBuffers()
        return result()
    }
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func isInside(_ path: String, root: String) -> Bool { path.hasPrefix(root == "/" ? "/" : root + "/") }
}
