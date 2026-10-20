import DuckpadDomain

public typealias FolderSearchProgress = @Sendable (FolderSearchResultSet) -> Void

/// A backend owns disk enumeration and may report incomplete, read-only previews.
/// Completed results still pass the same identity/range checks before replacement.
public protocol FolderSearchBackend: Sendable {
    func search(rootPath: String, query: SearchQuery, limits: FolderSearchLimits, excluding: FolderSearchExclusions,
                onProgress: FolderSearchProgress?) async throws(FolderSearchFailure) -> FolderSearchResultSet
}
