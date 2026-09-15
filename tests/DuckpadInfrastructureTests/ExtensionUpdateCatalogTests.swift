import CryptoKit
import Foundation
import Testing
import DuckpadDomain
@testable import DuckpadInfrastructure

@Suite struct ExtensionUpdateCatalogTests {
    private let key = Data(repeating: 7, count: 32)
    private func catalog(_ versions: [(String, String, String)], publisher: String = "com.duckpad", url: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": "com.duckpad.clipboard-history", "repository": "https://github.com/namJeongwan/duckpad-plugin-clipboard-history",
            "publisher": ["id": publisher, "keys": [["id": "release-1", "publicKey": key.base64EncodedString()]]],
            "releases": versions.map { version, minimum, maximum in
                ["version": version, "api": ["minimum": minimum, "maximumExclusive": maximum], "url": url ?? "https://github.com/namJeongwan/duckpad-plugin-clipboard-history/releases/download/v\(version)/Clipboard.zip", "sha256": String(repeating: "a", count: 64), "keyID": "release-1"] as [String: Any]
            }
        ])
    }
    private func decode(_ data: Data, status: Int = 200) throws -> ExtensionUpdate? {
        try ExtensionUpdateCatalogClient.decode(data, statusCode: status, id: ExtensionID(rawValue: "com.duckpad.clipboard-history"), installedVersion: SemanticVersion("0.2.0")!, hostAPI: SemanticVersion("1.3.0")!, publisherID: "com.duckpad", publisherFingerprint: SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined())
    }
    @Test func choosesNewestCompatibleVersionNumerically() throws {
        let update = try decode(catalog([("0.3.0", "1.3.0", "2.0.0"), ("0.10.0", "1.3.0", "2.0.0"), ("0.11.0", "1.4.0", "2.0.0")]))
        #expect(update?.version == SemanticVersion("0.10.0"))
    }
    @Test func doesNotOfferDowngradesDraftsOrMissingEntries() throws {
        #expect(try decode(catalog([])) == nil)
        #expect(try decode(catalog([("0.1.0", "1.0.0", "2.0.0"), ("0.2.0", "1.0.0", "2.0.0")])) == nil)
        #expect(try decode(Data(), status: 404) == nil)
    }
    @Test func rejectsPublisherChangesAndUnownedURLs() throws {
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(catalog([], publisher: "another.publisher")) }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(catalog([("0.3.0", "1.0.0", "2.0.0")], url: "https://github.com/other/plugin/releases/download/v0.3.0/Clipboard.zip")) }
    }
    @Test func rejectsDuplicatesAndAmbiguousVersions() throws {
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(catalog([("0.3.0", "1.0.0", "2.0.0"), ("0.3.0", "1.0.0", "2.0.0")])) }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(catalog([("0.03.0", "1.0.0", "2.0.0")])) }
    }
    @Test func acceptsEncodedAssetNamesButRejectsEncodedTraversal() throws {
        let base = "https://github.com/namJeongwan/duckpad-plugin-clipboard-history/releases/download/v0.3.0/"
        #expect(try decode(catalog([("0.3.0", "1.0.0", "2.0.0")], url: base + "Clipboard%20History.zip")) != nil)
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(catalog([("0.3.0", "1.0.0", "2.0.0")], url: base + "%2e%2e/Clipboard.zip")) }
    }
    @Test func refusesFailedChecksInsteadOfReportingNoUpdate() {
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try decode(Data(), status: 503) }
    }
}
