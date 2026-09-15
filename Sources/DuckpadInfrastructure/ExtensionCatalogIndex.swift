import Foundation
import DuckpadDomain

/// Discovery references only. Releases and publisher identity remain in each
/// plugin's catalog; an index entry does not itself make a draft installable.
struct ExtensionCatalogIndex: Decodable {
    struct Reference: Decodable { let id: String; let path: String }
    let schemaVersion: Int
    let plugins: [Reference]

    static func decode(_ data: Data, statusCode: Int) throws -> [ExtensionID] {
        guard statusCode == 200 else { throw ExtensionUpdateCatalogClient.Failure.unexpectedResponse }
        guard data.count <= 1_048_576 else { throw ExtensionUpdateCatalogClient.Failure.invalidCatalog }
        let index = try JSONDecoder().decode(Self.self, from: data)
        guard index.schemaVersion == 1, index.plugins.count <= 1_024 else { throw ExtensionUpdateCatalogClient.Failure.invalidCatalog }
        var seen: Set<String> = []
        return try index.plugins.map { entry in
            guard entry.id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$"#, options: .regularExpression) != nil,
                  entry.path == "plugins/\(entry.id).json", seen.insert(entry.id).inserted else {
                throw ExtensionUpdateCatalogClient.Failure.invalidCatalog
            }
            return ExtensionID(rawValue: entry.id)
        }
    }
}
