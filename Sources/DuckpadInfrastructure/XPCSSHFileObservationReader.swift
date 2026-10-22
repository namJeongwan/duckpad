import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import Foundation

/// The shipped app is sandboxed. OpenSSH runs in the existing authenticated
/// terminal helper, where the user's SSH config, keys and agent are available.
public struct XPCSSHFileObservationReader: RemoteFileBrowsing {
    private let configuration: URL?
    public init(configuration: URL? = nil) { self.configuration = configuration }
    public func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        guard case .ssh(let location) = source, maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024,
              RemoteFileLocation(host: location.host, path: location.path) != nil else { throw FileObservationError.invalidResponse }
        let decoded = try await perform(.init(location: location, cursor: cursor, maximumBytes: maximumBytes, configurationPath: configuration?.path))
        if let error = decoded.error { throw error }
        guard let read = decoded.read, read.data.count <= maximumBytes, read.cursor.offset <= read.sourceSize else {
            throw FileObservationError.invalidResponse
        }
        try Task.checkCancellation()
        return read
    }
}

extension XPCSSHFileObservationReader {
    public func configuredHosts() async throws -> [String] {
        var request = RemoteFileReadRequest(location: RemoteFileLocation(host: "localhost", path: "/")!, cursor: nil,
            maximumBytes: 1, configurationPath: configuration?.path)
        request.operation = .hosts
        guard let hosts = try await perform(request).hosts else { throw FileObservationError.invalidResponse }
        return hosts
    }
    public func directory(host: String, path: String?) async throws -> RemoteDirectoryListing {
        guard let location = RemoteFileLocation(host: host, path: path ?? "/") else { throw FileObservationError.invalidResponse }
        var request = RemoteFileReadRequest(location: location, cursor: nil, maximumBytes: 1, configurationPath: configuration?.path)
        request.operation = .directory; request.homeDirectory = path == nil
        guard let listing = try await perform(request).directory else { throw FileObservationError.invalidResponse }
        return listing
    }
    private func perform(_ request: RemoteFileReadRequest) async throws -> RemoteFileReadResponse {
        let data = try JSONEncoder().encode(request)
        let response = try await SSHServiceConnection.shared.request(data)
        try Task.checkCancellation()
        guard response.count <= 6 * 1_024 * 1_024 else { throw FileObservationError.invalidResponse }
        let decoded = try JSONDecoder().decode(RemoteFileReadResponse.self, from: response)
        if let error = decoded.error { throw error }
        return decoded
    }
}
