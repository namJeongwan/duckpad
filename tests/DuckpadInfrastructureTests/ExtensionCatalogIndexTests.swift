import Foundation
import Testing
import DuckpadDomain
@testable import DuckpadInfrastructure

@Suite struct ExtensionCatalogIndexTests {
    private func data(_ references: [[String: String]], schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "plugins": references])
    }
    private let reference = ["id": "com.duckpad.clipboard-history", "path": "plugins/com.duckpad.clipboard-history.json"]

    @Test func readsDiscoveryReferencesAndEmptyCatalog() throws {
        #expect(try ExtensionCatalogIndex.decode(data([reference]), statusCode: 200) == [.init(rawValue: "com.duckpad.clipboard-history")])
        #expect(try ExtensionCatalogIndex.decode(data([]), statusCode: 200).isEmpty)
    }
    @Test func rejectsDuplicatesAndNoncanonicalPaths() throws {
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(data([reference, reference]), statusCode: 200) }
        for path in ["../plugin.json", "https://example.com/plugin.json", "plugins/wrong.json", "plugins/%2e%2e/plugin.json"] {
            var value = reference; value["path"] = path
            #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(data([value]), statusCode: 200) }
        }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(data([["id": "../bad", "path": "plugins/../bad.json"]]), statusCode: 200) }
    }
    @Test func rejectsUnsupportedMissingOversizedAndTruncatedIndexes() throws {
        for status in [404, 503] {
            #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(Data(), statusCode: status) }
        }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(data([], schema: 2), statusCode: 200) }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(Data(repeating: 32, count: 1_048_577), statusCode: 200) }
        #expect(throws: ExtensionUpdateCatalogClient.Failure.self) { try ExtensionCatalogIndex.decode(data(Array(repeating: reference, count: 1_025)), statusCode: 200) }
        #expect(throws: (any Error).self) { try ExtensionCatalogIndex.decode(Data("{\"schemaVersion\":1".utf8), statusCode: 200) }
    }
}
