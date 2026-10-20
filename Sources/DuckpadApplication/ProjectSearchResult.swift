import DuckpadDomain

/// Open-buffer results and disk identities stay separate through replacement.
public struct ProjectSearchResult: Sendable {
    public let context: ProjectSearchContext?
    public let open: SearchResultSet
    public let folder: FolderSearchResultSet
    public var isTruncated: Bool { open.isTruncated || folder.isTruncated }
    public init(open: SearchResultSet, folder: FolderSearchResultSet, context: ProjectSearchContext? = nil) { self.open = open; self.folder = folder; self.context = context }
}
