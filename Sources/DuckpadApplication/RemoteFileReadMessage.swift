import DuckpadDomain
import Foundation

/// Bounded structured requests for the authenticated, unsandboxed SSH helper.
/// No command strings or SSH options cross this interface.
public enum RemoteFileOperation: String, Codable, Sendable { case read, directory, hosts }

public struct RemoteFileReadRequest: Codable, Sendable {
    public var operation: RemoteFileOperation = .read
    public var homeDirectory = false
    public let location: RemoteFileLocation
    public let cursor: FileObservationCursor?
    public let maximumBytes: Int
    public let configurationPath: String?
    public init(location: RemoteFileLocation, cursor: FileObservationCursor?, maximumBytes: Int, configurationPath: String? = nil) {
        self.location = location; self.cursor = cursor; self.maximumBytes = maximumBytes; self.configurationPath = configurationPath
    }
}

public struct RemoteFileReadResponse: Codable, Sendable {
    public let directory: RemoteDirectoryListing?
    public let hosts: [String]?
    public let read: FileObservationRead?
    public let error: FileObservationError?
    public init(read: FileObservationRead? = nil, error: FileObservationError? = nil,
                directory: RemoteDirectoryListing? = nil, hosts: [String]? = nil) {
        self.read = read; self.error = error; self.directory = directory; self.hosts = hosts
    }
}
