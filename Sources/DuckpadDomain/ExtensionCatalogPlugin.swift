import Foundation

public struct ExtensionCatalogPlugin: Equatable, Sendable {
    public let name: String
    public let descriptions: [String: String]
    public let release: ExtensionUpdate
    public let publisherFingerprint: String
    public init(name: String, descriptions: [String: String], release: ExtensionUpdate, publisherFingerprint: String) {
        self.name = name; self.descriptions = descriptions; self.release = release
        self.publisherFingerprint = publisherFingerprint
    }
    public func description(language: String) -> String {
        descriptions[language] ?? descriptions[String(language.split(separator: "-").first ?? "en")] ?? descriptions["en"] ?? ""
    }
}

public struct ExtensionCatalogSnapshot: Sendable {
    public let plugins: [ExtensionCatalogPlugin]
    public let hasFailures: Bool
    public init(plugins: [ExtensionCatalogPlugin], hasFailures: Bool = false) {
        self.plugins = plugins; self.hasFailures = hasFailures
    }
}
