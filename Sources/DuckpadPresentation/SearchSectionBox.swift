import AppKit

/// Search option sections share the same flat chrome as popup headers and footers.
@MainActor
final class SearchSectionBox: NSBox {
    override init(frame: NSRect) {
        super.init(frame: frame)
        boxType = .custom; borderType = .lineBorder; borderWidth = 1; cornerRadius = 6
        fillColor = WorkspaceColors.chrome; borderColor = WorkspaceColors.border
        titleFont = .systemFont(ofSize: 12, weight: .medium)
    }
    required init?(coder: NSCoder) { nil }
}
