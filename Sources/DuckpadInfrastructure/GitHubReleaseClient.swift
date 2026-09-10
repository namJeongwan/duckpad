import Foundation
import DuckpadDomain

public struct GitHubReleaseClient: Sendable {
    public enum Failure: Error { case unexpectedResponse, invalidRelease }

    private struct ReleasePayload: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func latestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: DuckpadProject.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Duckpad-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        return try Self.decodeRelease(data: data, statusCode: response.statusCode)
    }

    static func decodeRelease(data: Data, statusCode: Int) throws -> AppRelease? {
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw Failure.unexpectedResponse }
        guard data.count <= 1_048_576 else { throw Failure.invalidRelease }
        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let release = AppRelease(tag: payload.tag_name) else { throw Failure.invalidRelease }
        return release
    }
}
