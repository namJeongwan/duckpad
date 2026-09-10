import Foundation
import DuckpadDomain
@testable import DuckpadInfrastructure
import Testing

@Suite struct GitHubReleaseClientTests {
    @Test func decodesStableReleaseAndBuildsCanonicalProjectURL() throws {
        let data = Data(#"{"tag_name":"v0.10.0","draft":false,"prerelease":false,"html_url":"https://unrelated.example/download"}"#.utf8)
        let release = try #require(try GitHubReleaseClient.decodeRelease(data: data, statusCode: 200))
        #expect(release.version > SemanticVersion("0.9.9")!)
        #expect(release.url.absoluteString == "https://github.com/namJeongwan/duckpad/releases/tag/v0.10.0")
    }

    @Test func distinguishesNoReleaseFromNetworkAndPayloadFailures() throws {
        #expect(try GitHubReleaseClient.decodeRelease(data: Data(), statusCode: 404) == nil)
        for code in [403, 429, 500] {
            #expect(throws: GitHubReleaseClient.Failure.self) {
                try GitHubReleaseClient.decodeRelease(data: Data(), statusCode: code)
            }
        }
        for json in [
            #"{"tag_name":"v1.0.0-beta","draft":false,"prerelease":true}"#,
            #"{"tag_name":"v1.0.0","draft":true,"prerelease":false}"#,
            #"{"tag_name":"unexpected-tag","draft":false,"prerelease":false}"#,
            #"{}"#,
        ] {
            #expect(throws: (any Error).self) {
                try GitHubReleaseClient.decodeRelease(data: Data(json.utf8), statusCode: 200)
            }
        }
    }
}
