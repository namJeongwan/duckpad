import DuckpadDomain
import Foundation

public enum FormattingFailure: Error, Equatable, Sendable {
    case unsupportedLanguage
    case tooLarge
    case staleDocument
    case busy
    case timedOut
    case unavailable
    case invalidSyntax(String)
}

public struct FormattingRequest: Sendable {
    public let text: String
    public let parser: String
    public let settings: FormattingSettings

    public init(text: String, parser: String, settings: FormattingSettings = .init()) {
        self.text = text
        self.parser = parser
        self.settings = settings
    }
}

@MainActor
public protocol DocumentFormatting: AnyObject {
    func format(_ request: FormattingRequest) async throws -> String
}

public enum FormattingLanguage {
    public static func parser(languageID: String, filename: String, usesLanguageOverride: Bool) -> String? {
        // An explicit language choice wins over the filename, including Plain Text.
        if !usesLanguageOverride {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            let byExtension = [
                "js": "babel", "jsx": "babel", "mjs": "babel", "cjs": "babel",
                "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
                "json": "json", "jsonc": "jsonc", "json5": "json5", "geojson": "json",
                "yml": "yaml", "yaml": "yaml", "html": "html", "htm": "html", "vue": "vue",
                "css": "css", "scss": "scss", "less": "less", "md": "markdown", "mdx": "mdx",
                "markdown": "markdown", "graphql": "graphql", "gql": "graphql", "hbs": "glimmer",
                "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "svg": "xml", "sql": "sql",
            ]
            if let parser = byExtension[ext] { return parser }
        }
        return [
            "javascript": "babel", "typescript": "typescript", "json": "json", "yaml": "yaml",
            "html": "html", "css": "css", "scss": "scss", "less": "less", "markdown": "markdown",
            "graphql": "graphql", "xml": "xml", "sql": "sql", "vue": "vue",
        ][languageID]
    }
}
