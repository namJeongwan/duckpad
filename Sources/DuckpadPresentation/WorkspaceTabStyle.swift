import AppKit

/// Shared typography and interaction colors for document and terminal tabs.
@MainActor
enum WorkspaceTabStyle {
    static var font: NSFont { .systemFont(ofSize: 12) }

    static func background(selected: Bool, hovered: Bool) -> NSColor {
        if hovered { return .controlAccentColor.withAlphaComponent(selected ? 0.13 : 0.11) }
        return selected ? WorkspaceColors.editor : WorkspaceColors.panel
    }

    static func separator(selected: Bool, hovered: Bool) -> NSColor {
        hovered ? .controlAccentColor.withAlphaComponent(selected ? 0.48 : 0.34) : WorkspaceColors.border
    }

    static func title(selected: Bool, hovered: Bool) -> NSColor {
        selected || hovered ? .labelColor : .secondaryLabelColor
    }
}
