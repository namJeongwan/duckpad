import Foundation

public struct AppRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let url: URL

    public init?(tag: String) {
        let versionText = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let version = Self.parseVersion(versionText) else { return nil }
        self.version = version
        url = DuckpadProject.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }

    public static func parseVersion(_ text: String) -> SemanticVersion? {
        SemanticVersion(text.split(separator: ".", omittingEmptySubsequences: false).count == 2 ? text + ".0" : text)
    }
}
