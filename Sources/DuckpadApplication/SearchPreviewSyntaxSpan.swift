import DuckpadDomain

/// Display-only native lexer colors over UTF-8 offsets in a preview excerpt.
public struct SearchPreviewSyntaxSpan: Equatable, Sendable {
    public let range: SearchUTF8Range
    public let lightForeground: Int
    public let darkForeground: Int

    public init(range: SearchUTF8Range, lightForeground: Int, darkForeground: Int) {
        self.range = range
        self.lightForeground = lightForeground
        self.darkForeground = darkForeground
    }
}
