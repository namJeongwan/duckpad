import CryptoKit
import Foundation
import Testing
import DuckpadDomain
@testable import DuckpadInfrastructure

@Suite struct ExtensionUpdateCatalogTests {
    private let key = Data(repeating: 7, count: 32)
    private func catalog(_ versions: [(String, String, String)], publisher: String = "com.duckpad", url: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "name": "Clipboard History", "description": ["en": "Search clipboard history", "ko": "클립보드 기록 검색"],
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
    @Test func discoveryFindsCompatibleUninstalledPluginAndLocalizedMetadata() throws {
        let data = try catalog([("0.2.1", "1.3.0", "2.0.0"), ("0.3.0", "2.0.0", "3.0.0")])
        let plugin = try #require(try ExtensionUpdateCatalogClient.decodePlugin(data, statusCode: 200,
            id: .init(rawValue: "com.duckpad.clipboard-history"), hostAPI: .init(major: 1, minor: 3, patch: 0)))
        #expect(plugin.release.version == SemanticVersion("0.2.1"))
        #expect(plugin.description(language: "ko-KR") == "클립보드 기록 검색")
        #expect(plugin.description(language: "ja") == "Search clipboard history")
        #expect(plugin.publisherFingerprint == SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined())
    }
    @Test func discoveryHidesDraftsAndIncompatibleReleasesButReportsBrokenEntries() throws {
        let id = ExtensionID(rawValue: "com.duckpad.clipboard-history")
        let api = SemanticVersion(major: 1, minor: 3, patch: 0)
        #expect(try ExtensionUpdateCatalogClient.decodePlugin(catalog([]), statusCode: 200, id: id, hostAPI: api) == nil)
        #expect(try ExtensionUpdateCatalogClient.decodePlugin(catalog([("0.3.0", "2.0.0", "3.0.0")]), statusCode: 200, id: id, hostAPI: api) == nil)
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) {
            try ExtensionUpdateCatalogClient.decodePlugin(Data(), statusCode: 404, id: id, hostAPI: api)
        }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) {
            try ExtensionUpdateCatalogClient.decodePlugin(catalog([("0.3.0", "1.3.0", "2.0.0")], url: "https://github.com/other/plugin/releases/download/v0.3.0/Clipboard.zip"), statusCode: 200, id: id, hostAPI: api)
        }
    }

    @Test func brokenEntryDoesNotHideHealthyPlugins() async throws {
        let healthy = ExtensionID(rawValue: "com.duckpad.clipboard-history")
        let broken = ExtensionID(rawValue: "com.example.broken")
        let data = try catalog([("0.2.1", "1.3.0", "2.0.0")])
        let snapshot = try await ExtensionUpdateCatalogClient.collect(ids: [healthy, broken], hostAPI: .init(major: 1, minor: 3, patch: 0)) { id in
            id == healthy ? (data, 200) : (Data(), 404)
        }
        #expect(snapshot.plugins.map { $0.release.extensionID } == [healthy])
        #expect(snapshot.hasFailures)
    }
    @Test func liveCatalogPackagePassesDownloadAndSignatureVerification() async throws {
        guard ProcessInfo.processInfo.environment["DUCKPAD_LIVE_CATALOG_SMOKE"] == "1" else { return }
        let snapshot = try await ExtensionUpdateCatalogClient().availablePlugins(hostAPI: .init(major: 1, minor: 3, patch: 0))
        #expect(!snapshot.hasFailures)
        let plugin = try #require(snapshot.plugins.first { $0.release.extensionID.rawValue == "com.duckpad.clipboard-history" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-catalog-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = LocalExtensionPackageLoader(root: root, bundledPackages: [])
        let installer = ExtensionUpdateInstaller(loader: loader, nativeInstaller: { _ in })
        let prepared = try await installer.prepare(plugin.release, publisherFingerprint: plugin.publisherFingerprint)
        #expect(prepared.package.manifest.id == plugin.release.extensionID)
        #expect(prepared.package.manifest.runtime.kind == "native")
        // Verify the real install path into an isolated profile, without loading the clipboard collector.
        try await installer.install(prepared)
        let discovered = await loader.discover()
        #expect(discovered.failures.isEmpty)
        #expect(discovered.packages.map { $0.manifest.id } == [plugin.release.extensionID])
    }

}
