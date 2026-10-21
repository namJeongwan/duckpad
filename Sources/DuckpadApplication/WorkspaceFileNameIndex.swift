import Foundation
import DuckpadDomain

public struct WorkspaceFileNameIndex: Sendable {
    public let files: [WorkspaceBrowserEntry]
    public let isTruncated: Bool
    public let skippedDirectoryCount: Int

    public init(files: [WorkspaceBrowserEntry], isTruncated: Bool, skippedDirectoryCount: Int) {
        self.files = files; self.isTruncated = isTruncated; self.skippedDirectoryCount = skippedDirectoryCount
    }
}

extension WorkspaceBrowserUseCase {
    /// Reads names through the workspace's existing access checks; never reads file contents.
    public func fileNameIndex(maximumEntries: Int = 20_000, query: String = "") async throws -> WorkspaceFileNameIndex {
        guard maximumEntries > 0, maximumEntries <= 100_000 else { throw WorkspaceBrowserFailure.entryLimitExceeded(maximumEntries) }
        var files: [WorkspaceBrowserEntry] = [], skipped = 0, truncated = false
        let originalRoots = roots
        for root in originalRoots where root.isAvailable {
            try Task.checkCancellation()
            guard files.count < maximumEntries else { truncated = true; break }
            let result = try await searchFileNames(rootID: root.id, query: query, maximumEntries: maximumEntries - files.count)
            guard roots == originalRoots else { throw CancellationError() }
            files += result.files; skipped += result.skippedDirectoryCount
            truncated = truncated || result.isTruncated
        }
        return .init(files: files, isTruncated: truncated, skippedDirectoryCount: skipped)
    }
}

public extension WorkspaceRootStore {
    /// Compatibility for workspace providers without a native name-search backend.
    func fileNameIndex(rootID: WorkspaceRootID, query: String, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> WorkspaceFileNameIndex {
        let pattern = FileNameQuery(query)
        var queue = [(rootID, "", 0)]
        var files: [WorkspaceBrowserEntry] = []
        var cursor = 0, observed = 0, skipped = 0, nameBytes = 0
        var discovered = 0, discoveryBytes = 0
        let deadline = ContinuousClock.now + .seconds(30)
        while cursor < queue.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return .init(files: files, isTruncated: true, skippedDirectoryCount: skipped) }
            let (root, directory, depth) = queue[cursor]; cursor += 1
            guard depth < 128 else { skipped += 1; continue }
            let entries: [WorkspaceBrowserEntry]
            do { entries = try await children(rootID: root, relativeDirectory: directory, includeHiddenFiles: includeHiddenFiles) }
            catch is CancellationError { throw CancellationError() }
            catch WorkspaceBrowserFailure.cancelled { throw CancellationError() }
            catch { skipped += 1; continue }
            for entry in entries {
                discovered += 1; discoveryBytes += entry.relativePath.utf8.count
                guard discovered <= 100_000, discoveryBytes <= 32 * 1_024 * 1_024 else {
                    return .init(files: files, isTruncated: true, skippedDirectoryCount: skipped)
                }
                if entry.kind == .directory { queue.append((root, entry.relativePath, depth + 1)) }
                if !pattern.isEmpty && (entry.kind != .file || !pattern.matches(path: entry.relativePath)) { continue }
                guard observed < maximumEntries, nameBytes + entry.relativePath.utf8.count <= 16 * 1_024 * 1_024 else {
                    return WorkspaceFileNameIndex(files: files, isTruncated: true, skippedDirectoryCount: skipped)
                }
                observed += 1
                nameBytes += entry.relativePath.utf8.count
                if entry.kind == .file { files.append(entry) }
            }
        }
        try Task.checkCancellation()
        return WorkspaceFileNameIndex(files: files, isTruncated: false, skippedDirectoryCount: skipped)
    }
}
