import DuckpadDomain

/// Retains completed open-buffer edits when preparing disk targets fails or stops.
@MainActor
public final class ProjectDocumentsReplaceUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private let files: FileDocumentUseCase
    private let search: SearchWorkspaceUseCase
    public init(workspace: ScratchWorkspaceUseCase, files: FileDocumentUseCase, search: SearchWorkspaceUseCase) {
        self.workspace = workspace; self.files = files; self.search = search
    }
    public func replace(_ query: SearchQuery, preview: ProjectSearchResult) async throws -> OpenDocumentsReplacementResult {
        guard !preview.isTruncated else { throw SearchFailure.invalidLimits }
        let open = try await Self.replaceOpen(query, preview: preview.open, search: search)
        guard !preview.folder.documents.isEmpty else { return open }
        do {
            let disk = try await FolderDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: preview.folder)
            return .init(documents: open.documents + disk.documents, wasCancelled: open.wasCancelled || disk.wasCancelled)
        } catch {
            let cancelled = Task.isCancelled || (error as? SearchFailure) == .cancelled
            let pending = preview.folder.documents.map { document in
                OpenDocumentReplacement(tabID: workspace.tabID(canonicalPath: document.path) ?? TabID(), title: document.relativePath,
                    status: cancelled ? .cancelled : .unavailable)
            }
            return .init(documents: open.documents + pending, wasCancelled: open.wasCancelled || cancelled)
        }
    }
    public static func replaceOpen(_ query: SearchQuery, preview: SearchResultSet, search: SearchWorkspaceUseCase) async throws -> OpenDocumentsReplacementResult {
        guard !preview.isTruncated else { throw SearchFailure.invalidLimits }
        guard !preview.documents.isEmpty else { return .init(documents: [], wasCancelled: Task.isCancelled) }
        let matches = preview.documents.flatMap(\.matches)
        let revisions = Dictionary(matches.map { ($0.bufferID, $0.revision) }, uniquingKeysWith: { first, _ in first })
        return try await search.replaceAllOpenDocuments(query, only: Set(preview.documents.map(\.tabID)), expectedRevisions: revisions,
            expectedDocuments: preview.documents, expectedRanges: Dictionary(grouping: matches, by: \.bufferID).mapValues { Set($0.map(\.range)) })
    }
}
