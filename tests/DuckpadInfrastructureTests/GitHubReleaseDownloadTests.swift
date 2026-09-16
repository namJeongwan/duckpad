import Foundation
@testable import DuckpadInfrastructure
import Testing

private final class ReleaseResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Duckpad-Test-Response") ?? "valid"
        let headers = scenario == "oversized-header" ? ["Content-Length": "1048577"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var body = Data(#"{"tag_name":"v1.0.0","draft":false,"prerelease":false}"#.utf8)
        if scenario == "oversized-body" { body.append(Data(repeating: 0x20, count: 1_048_576)) }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct GitHubReleaseDownloadTests {
    private func session(_ scenario: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseResponseProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Duckpad-Test-Response": scenario]
        return URLSession(configuration: configuration)
    }

    @Test func rejectsOversizedDeclaredResponseBeforeDecodingSmallBody() async throws {
        let session = session("oversized-header")
        defer { session.invalidateAndCancel() }
        await #expect(throws: GitHubReleaseClient.Failure.self) {
            _ = try await GitHubReleaseClient(session: session).latestRelease()
        }
    }

    @Test func rejectsOversizedBodyWithoutContentLength() async throws {
        let session = session("oversized-body")
        defer { session.invalidateAndCancel() }
        await #expect(throws: GitHubReleaseClient.Failure.self) {
            _ = try await GitHubReleaseClient(session: session).latestRelease()
        }
    }

    @Test func acceptsValidReleaseWithoutContentLength() async throws {
        let session = session("valid")
        defer { session.invalidateAndCancel() }
        let release = try await GitHubReleaseClient(session: session).latestRelease()
        #expect(release?.version.description == "1.0.0")
    }
}
