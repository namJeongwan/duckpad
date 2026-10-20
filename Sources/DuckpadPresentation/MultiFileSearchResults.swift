import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

enum MultiFileSearchResults: Sendable {
    case open(SearchResultSet)
    case folder(FolderSearchResultSet)
    case combined(ProjectSearchResult)

    static let maximumDisplayedRows = 5000

    struct Row: Sendable {
        enum Target: Sendable { case open(SearchMatch); case folder(FolderSearchDocumentResult, FolderSearchMatch); case document(TabID) }
        let title: String
        let detail: String
        let snippet: String?
        let target: Target?
    }

    var isTruncated: Bool {
        switch self { case .open(let r): r.isTruncated; case .folder(let r): r.isTruncated; case .combined(let r): r.isTruncated }
    }
    var matchCount: Int {
        switch self { case .open(let r): r.matchCount; case .folder(let r): r.matchCount; case .combined(let r): r.open.matchCount + r.folder.matchCount }
    }
    var documentCount: Int {
        switch self { case .open(let r): r.documents.count; case .folder(let r): r.documents.count; case .combined(let r): r.open.documents.count + r.folder.documents.count }
    }
    var skippedCount: Int {
        switch self { case .open: 0; case .folder(let r): r.skippedFileCount; case .combined(let r): r.folder.skippedFileCount }
    }
    var openMatches: [SearchMatch] {
        if case .open(let result) = self { return result.documents.flatMap(\.matches) }
        if case .combined(let result) = self { return result.open.documents.flatMap(\.matches) }
        return []
    }
    func rows(catalog: LocalizationCatalog, maximumRows: Int = Self.maximumDisplayedRows) -> [Row] {
        var rows: [Row] = []
        switch self {
        case .combined(let result):
            let openRows = Self.open(result.open).rows(catalog: catalog, maximumRows: maximumRows)
            return openRows + Self.folder(result.folder).rows(catalog: catalog, maximumRows: max(0, maximumRows - openRows.count))
        case .open(let result):
            for document in result.documents {
                let title = LocalizedDocumentTitle.text(document.title, generated: document.generatedTitle, catalog: catalog)
                for match in document.matches {
                    guard rows.count < maximumRows else { return rows }
                    rows.append(Row(title: match.snippet, detail: "\(title)  \(match.line)", snippet: match.snippet, target: .open(match)))
                }
            }
        case .folder(let result):
            for document in result.documents {
                for match in document.matches {
                    guard rows.count < maximumRows else { return rows }
                    rows.append(Row(title: match.snippet, detail: "\(document.relativePath)  \(match.line)", snippet: match.snippet, target: .folder(document, match)))
                }
            }
        }
        return rows
    }

    static func replacementRows(_ result: OpenDocumentsReplacementResult, catalog: LocalizationCatalog) -> [Row] {
        result.documents.map { document in
            let detail: String
            switch document.status {
            case .replaced(let count): detail = catalog.text("search.replaced", arguments: [count])
            case .noChanges: detail = catalog.text("No changes needed")
            case .readOnly: detail = catalog.text("Skipped: read-only")
            case .unavailable: detail = catalog.text("Skipped: document unavailable")
            case .changed: detail = catalog.text("Skipped: document changed")
            case .limitExceeded: detail = catalog.text("Skipped: size or match limit")
            case .timedOut: detail = catalog.text("Skipped: search timed out")
            case .cancelled: detail = catalog.text("Not processed: cancelled")
            }
            return Row(title: LocalizedDocumentTitle.text(document.title, generated: document.generatedTitle, catalog: catalog),
                       detail: detail, snippet: nil, target: .document(document.tabID))
        }
    }
}
