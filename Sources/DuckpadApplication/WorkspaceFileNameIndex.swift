import Foundation

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
    public func fileNameIndex(maximumEntries: Int = 20_000) async throws -> WorkspaceFileNameIndex {
        guard maximumEntries > 0, maximumEntries <= 100_000 else { throw WorkspaceBrowserFailure.entryLimitExceeded(maximumEntries) }
        var queue = roots.filter(\.isAvailable).map { ($0.id, "", 0) }
        var files: [WorkspaceBrowserEntry] = []
        var cursor = 0, observed = 0, skipped = 0, nameBytes = 0
        while cursor < queue.count {
            try Task.checkCancellation()
            let (root, directory, depth) = queue[cursor]; cursor += 1
            guard depth < 128 else { skipped += 1; continue }
            let entries: [WorkspaceBrowserEntry]
            do { entries = try await children(rootID: root, relativeDirectory: directory) }
            catch { skipped += 1; continue }
            for entry in entries {
                guard observed < maximumEntries, nameBytes + entry.relativePath.utf8.count <= 16 * 1_024 * 1_024 else {
                    return WorkspaceFileNameIndex(files: files, isTruncated: true, skippedDirectoryCount: skipped)
                }
                observed += 1
                nameBytes += entry.relativePath.utf8.count
                if entry.kind == .file { files.append(entry) }
                else { queue.append((root, entry.relativePath, depth + 1)) }
            }
        }
        try Task.checkCancellation()
        return WorkspaceFileNameIndex(files: files, isTruncated: false, skippedDirectoryCount: skipped)
    }
}
