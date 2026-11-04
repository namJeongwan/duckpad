import AppKit

/// The host supplies its editor palette; the UI owns no Duckpad theme policy.
public struct CodeSuggestionTheme {
    public let background: NSColor
    public let border: NSColor
    public let foreground: NSColor
    public let secondary: NSColor
    public let selection: NSColor
    public let accent: NSColor
    public init(background: NSColor, border: NSColor, foreground: NSColor, secondary: NSColor, selection: NSColor, accent: NSColor) {
        self.background = background; self.border = border; self.foreground = foreground
        self.secondary = secondary; self.selection = selection; self.accent = accent
    }
    static var system: Self {
        .init(background: .windowBackgroundColor, border: .separatorColor, foreground: .labelColor,
              secondary: .secondaryLabelColor, selection: .selectedTextBackgroundColor, accent: .controlAccentColor)
    }
}
