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
    func readFile(in folder: URL, root: FolderFileNameRoot, relativePath: String) async throws -> WorkspaceFileRead
}
