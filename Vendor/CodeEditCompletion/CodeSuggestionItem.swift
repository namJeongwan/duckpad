import AppKit

/// Adapted from CodeEditSourceEditor's CodeSuggestionEntry (MIT).
public struct CodeSuggestionItem {
    public var label: String
    public var detail: String
    public var documentation: String
    public var symbol: String
    public var color: NSColor
    public var matchedRanges: [NSRange]
    public init(label: String, detail: String, documentation: String, symbol: String,
                color: NSColor, matchedRanges: [NSRange]) {
        self.label = label; self.detail = detail; self.documentation = documentation
        self.symbol = symbol; self.color = color; self.matchedRanges = matchedRanges
    }
}
