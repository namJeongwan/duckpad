import DuckpadApplication

public struct FileObservationReader: RemoteFileBrowsing {
    private let local = LocalFileObservationReader()
    private let remote = XPCSSHFileObservationReader()
    public init() {}
    public func configuredHosts() async throws -> [String] { try await remote.configuredHosts() }
    public func directory(host: String, path: String?) async throws -> RemoteDirectoryListing {
        try await remote.directory(host: host, path: path)
    }
    public func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        switch source {
        case .local: try await local.read(source, after: cursor, maximumBytes: maximumBytes)
        case .ssh: try await remote.read(source, after: cursor, maximumBytes: maximumBytes)
        }
    }
}
