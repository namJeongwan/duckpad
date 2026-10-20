import Foundation
import DuckpadApplication
import DuckpadDomain

struct FileNameSearchEntry: Sendable {
    enum Target: Sendable { case tab(TabID); case workspace(WorkspaceBrowserEntry); case folder(root: URL, authority: FolderFileNameRoot, relativePath: String) }
    let name: String
    let path: String
    let target: Target
    let project: String?
    private let foldedName: String
    private let foldedPath: String

    init(name: String, path: String, target: Target, project: String? = nil) {
        self.name = name; self.path = path; self.target = target; self.project = project
        foldedName = Self.fold(name); foldedPath = Self.fold(path)
    }

    static func matching(_ entries: [Self], query: String, limit: Int = 100) -> [Self] {
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(entries.prefix(limit)) }
        let phrase = terms.joined(separator: " ")
        return entries.enumerated().compactMap { index, entry -> (Int, Int)? in
            guard !Task.isCancelled else { return nil }
            guard terms.allSatisfy({ entry.foldedName.contains($0) || entry.foldedPath.contains($0) }) else { return nil }
            let rank = entry.foldedName == phrase ? 0 : entry.foldedName.hasPrefix(phrase) ? 1
                : entry.foldedName.contains(phrase) ? 2 : terms.allSatisfy({ entry.foldedName.contains($0) }) ? 3 : 4
            return (index, rank)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(limit).map { entries[$0.0] }
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
