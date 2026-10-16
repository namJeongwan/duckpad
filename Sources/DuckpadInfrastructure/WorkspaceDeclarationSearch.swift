import Foundation
import DuckpadApplication

/// Uses the existing security-scoped root store. No implicit access to parent folders.
public actor WorkspaceDeclarationSearch: DeclarationProjectSearching {
    private let store: LocalWorkspaceRootStore
    private let analyzer: any DeclarationAnalyzing
    private let excluded: Set<String> = [".git", ".svn", ".hg", ".build", ".worktrees", "node_modules", "vendor", "Vendor", "Pods", "build", "dist", "target", "__pycache__", ".venv"]
    public init(store: LocalWorkspaceRootStore, analyzer: any DeclarationAnalyzing = BuiltinDeclarationAnalyzer()) {
        self.store = store; self.analyzer = analyzer
    }
    public func find(name: String, language: String, kind: SymbolNavigationKind, roots: [WorkspaceRoot], excludingPaths: Set<String>) async -> DeclarationProjectResult {
        var queue = roots.filter(\.isAvailable).map { ($0, "") }
        var cursor = 0, fileCount = 0, byteCount = 0, entryCount = 0
        var visitedPaths = excludingPaths
        var matches: [DeclarationFileMatch] = [], complete = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cursor < queue.count {
            guard !Task.isCancelled, ContinuousClock.now < deadline, cursor < 256, entryCount < 10_000, fileCount < 512, byteCount < 32 * 1_024 * 1_024, matches.count < 200 else { complete = false; break }
            let (root, directory) = queue[cursor]; cursor += 1
            guard let entries = try? await store.children(rootID: root.id, relativeDirectory: directory) else { complete = false; continue }
            for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
                entryCount += 1
                guard !Task.isCancelled, ContinuousClock.now < deadline, fileCount < 512, entryCount <= 10_000, matches.count < 200 else { complete = false; break }
                if entry.kind == .directory {
                    if !excluded.contains(entry.name), !entry.name.hasPrefix(".") {
                        if queue.count < 256 { queue.append((root, entry.relativePath)) }
                        else { complete = false }
                    }
                    continue
                }
                guard let fileLanguage = DeclarationLanguage.forFilename(entry.name), DeclarationLanguage.isCompatible(language, fileLanguage) else { continue }
                let path = URL(fileURLWithPath: root.canonicalPath).appendingPathComponent(entry.relativePath).path
                guard visitedPaths.insert(path).inserted else { continue }
                fileCount += 1
                let remaining = min(DeclarationIndex.maximumBytes, 32 * 1_024 * 1_024 - byteCount)
                guard remaining > 0 else { complete = false; break }
                guard let file = try? await store.readFile(entry, maximumBytes: UInt64(remaining)),
                      !file.result.data.contains(0), String(data: file.result.data, encoding: .utf8) != nil else { complete = false; continue }
                byteCount += file.result.data.count
                let index = await analyzer.index(utf8: file.result.data, language: fileLanguage)
                complete = complete && index.isComplete
                for match in index.matches(named: name, kind: kind) {
                    guard matches.count < 200 else { complete = false; break }
                    matches.append(DeclarationFileMatch(url: file.url, utf8: file.result.data, match: match))
                }
            }
        }
        return DeclarationProjectResult(matches: matches, isComplete: complete && !Task.isCancelled)
    }
}
