import DuckpadDomain
import Foundation

/// Folder replacement stages edits in normal, recoverable document buffers.
/// The existing file activation gate rejects stale disk identities and dirty buffers.
@MainActor
public final class FolderDocumentsReplaceUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private let files: FileDocumentUseCase
    private let search: SearchWorkspaceUseCase

    public init(workspace: ScratchWorkspaceUseCase, files: FileDocumentUseCase, search: SearchWorkspaceUseCase) {
        self.workspace = workspace; self.files = files; self.search = search
    }

    public func replace(_ query: SearchQuery, preview: FolderSearchResultSet) async throws -> OpenDocumentsReplacementResult {
        guard !preview.isTruncated else { throw SearchFailure.invalidLimits }
        var accepted = Set<TabID>()
        var revisions: [BufferID: UInt64] = [:]
        var ranges: [BufferID: Set<SearchUTF8Range>] = [:]
        var expected: [SearchDocumentResult] = []
        var skipped: [OpenDocumentReplacement] = []
        // Opening thousands of tabs at once is not an acceptable UI operation.
        let maximumDocuments = 200
        for (index, document) in preview.documents.enumerated() {
            let status: OpenDocumentReplacement.Status
            if Task.isCancelled { status = .cancelled }
            else if index >= maximumDocuments { status = .limitExceeded }
            else if !document.matches.isEmpty {
                switch await files.prepareFolderSearchDocument(document) {
                case .opened(let id), .activatedExisting(let id):
                    if let context = workspace.fileContext(tabID: id) {
                        accepted.insert(id); revisions[context.buffer.bufferID] = context.buffer.revision
                        ranges[context.buffer.bufferID] = Set(document.matches.map(\.range))
                        expected.append(.init(tabID: id, title: context.title, matches: []))
                        continue
                    }
                    status = .unavailable
                case .failed(.comparisonInvalidated): status = .changed
                case .failed: status = Task.isCancelled ? .cancelled : .unavailable
                }
            } else { continue }
            let id = workspace.snapshot().tabs.first { $0.fullPath == document.path }?.id ?? TabID()
            skipped.append(.init(tabID: id, title: document.relativePath, status: status))
        }
        guard !Task.isCancelled else {
            let unprocessed = expected.map {
                OpenDocumentReplacement(tabID: $0.tabID, title: $0.title, status: .cancelled, generatedTitle: $0.generatedTitle)
            }
            return .init(documents: skipped + unprocessed, wasCancelled: true)
        }
        let result = try await search.replaceAllOpenDocuments(query, only: accepted, expectedRevisions: revisions, expectedDocuments: expected, expectedRanges: ranges)
        return .init(documents: result.documents + skipped, wasCancelled: result.wasCancelled)
    }
}
