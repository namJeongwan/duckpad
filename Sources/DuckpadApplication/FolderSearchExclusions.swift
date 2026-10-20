import Foundation

/// Canonical paths already owned by editor buffers or a more specific root.
public struct FolderSearchExclusions: Sendable {
    public var paths: Set<String>
    public var directories: [String]
    public init(paths: Set<String> = [], directories: [String] = []) { self.paths = paths; self.directories = directories }
    public func contains(_ path: String) -> Bool {
        paths.contains(path) || directories.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }
}
