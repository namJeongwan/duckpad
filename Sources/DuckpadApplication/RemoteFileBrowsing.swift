import DuckpadDomain
import Foundation

public struct RemoteDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) { self.name = name; self.isDirectory = isDirectory }
}

public struct RemoteDirectoryListing: Codable, Equatable, Sendable {
    public let path: String
    public let entries: [RemoteDirectoryEntry]
    public let isTruncated: Bool
    public init(path: String, entries: [RemoteDirectoryEntry], isTruncated: Bool = false) {
        self.path = path; self.entries = entries; self.isTruncated = isTruncated
    }
}

public protocol RemoteFileBrowsing: FileObservationReading {
    func configuredHosts() async throws -> [String]
    /// Nil selects the remote account's home directory.
    func directory(host: String, path: String?) async throws -> RemoteDirectoryListing
}
