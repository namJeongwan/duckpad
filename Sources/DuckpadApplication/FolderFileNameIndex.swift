import Foundation

public struct FolderFileNameRoot: Equatable, Sendable {
    public let canonicalPath: String
    public let device: UInt64
    public let inode: UInt64
    public init(canonicalPath: String, device: UInt64, inode: UInt64) {
        self.canonicalPath = canonicalPath; self.device = device; self.inode = inode
    }
}

/// Names only: file content and editor buffers are never read while indexing.
public struct FolderFileNameIndex: Sendable {
    public let root: FolderFileNameRoot
    public var rootPath: String { root.canonicalPath }
    public let relativePaths: [String]
    public let isTruncated: Bool
    public let skippedCount: Int

    public init(root: FolderFileNameRoot, relativePaths: [String], isTruncated: Bool, skippedCount: Int) {
        self.root = root; self.relativePaths = relativePaths
        self.isTruncated = isTruncated; self.skippedCount = skippedCount
    }
}

public protocol FolderFileNameIndexing: Sendable {
    func index(in folder: URL, maximumEntries: Int) async throws -> FolderFileNameIndex
    func index(in folder: URL, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> FolderFileNameIndex
    func search(in folder: URL, query: String, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> FolderFileNameIndex
    func readFile(in folder: URL, root: FolderFileNameRoot, relativePath: String) async throws -> WorkspaceFileRead
}

public extension FolderFileNameIndexing {
    func search(in folder: URL, query: String, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> FolderFileNameIndex {
        let result = try await index(in: folder, maximumEntries: maximumEntries, includeHiddenFiles: includeHiddenFiles)
        let pattern = FileNameQuery(query)
        return .init(root: result.root, relativePaths: result.relativePaths.filter {
            pattern.rank(name: URL(fileURLWithPath: $0).lastPathComponent, path: result.rootPath + "/" + $0) != nil
        }, isTruncated: result.isTruncated, skippedCount: result.skippedCount)
    }
    func index(in folder: URL, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> FolderFileNameIndex {
        try await index(in: folder, maximumEntries: maximumEntries)
    }
}
