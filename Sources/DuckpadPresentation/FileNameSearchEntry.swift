import Foundation
import DuckpadApplication
import DuckpadDomain

typealias FileNameSearchResult = (entries: [FileNameSearchEntry], truncated: Bool, skipped: Int)
typealias FileNameSearchProgress = @MainActor @Sendable (FileNameSearchResult) -> Void

struct FileNameSearchEntry: Sendable {
    enum Target: Hashable, Sendable { case tab(TabID); case workspace(WorkspaceBrowserEntry); case folder(root: URL, authority: FolderFileNameRoot, relativePath: String) }
    let name: String
    let path: String
    let target: Target
    let project: String?
    private let foldedName: String
    private let foldedPath: String

    init(name: String, path: String, target: Target, project: String? = nil) {
        self.name = name; self.path = path; self.target = target; self.project = project
        foldedName = FileNameQuery.fold(name); foldedPath = FileNameQuery.fold(path)
    }

    static func matching(_ entries: [Self], query: String, limit: Int = 100) -> [Self] {
        let pattern = FileNameQuery(query)
        guard !pattern.isEmpty else { return Array(entries.prefix(limit)) }
        return entries.enumerated().compactMap { index, entry -> (Int, Int)? in
            guard !Task.isCancelled else { return nil }
            guard let rank = pattern.rank(foldedName: entry.foldedName, foldedPath: entry.foldedPath) else { return nil }
            return (index, rank)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(limit).map { entries[$0.0] }
    }

}
