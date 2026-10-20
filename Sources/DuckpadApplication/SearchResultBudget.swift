import DuckpadDomain

/// One estimate is used for admission and for sharing a budget across roots.
public enum SearchResultBudget {
    public static let baseBytes = 64
    public static func documentBytes(title: String) -> Int { title.utf8.count + 512 }
    public static func matchBytes(_ match: SearchMatch) -> Int {
        match.snippet.utf8.count + 128 + match.captures.count * MemoryLayout<SearchUTF8Range?>.stride + (match.replacementUTF8?.count ?? 0)
    }
    public static func bytes(_ value: SearchResultSet) -> Int {
        value.documents.reduce(baseBytes) { $0 + documentBytes(title: $1.title) + $1.matches.reduce(0) { $0 + matchBytes($1) } }
    }
    public static func bytes(_ value: FolderSearchResultSet) -> Int {
        value.documents.reduce(value.rootPath.utf8.count + baseBytes) { total, doc in
            total + doc.path.utf8.count + doc.relativePath.utf8.count + doc.identity.canonicalPath.utf8.count
                + doc.identity.contentToken.utf8.count + 384 + MemoryLayout<Int>.stride
                + doc.matches.reduce(0) { $0 + $1.snippet.utf8.count + 128 }
        }
    }
}
