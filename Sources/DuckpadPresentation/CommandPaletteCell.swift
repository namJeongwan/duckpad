import AppKit
import DuckpadLocalization

/// Shared command rows for editor and terminal commands.
@MainActor
final class CommandPaletteCell: NSTableCellView {
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let labels = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = title
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.addArrangedSubview(title)
        labels.addArrangedSubview(detail)
        for view in [labels, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -16),
            title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ command: CommandPaletteCommand, enabled: Bool, catalog: LocalizationCatalog) {
        textField?.stringValue = command.title
        textField?.textColor = enabled ? .labelColor : .disabledControlTextColor
        detail.stringValue = command.path
        detail.isHidden = command.path.isEmpty
        shortcut.stringValue = command.shortcut
        toolTip = command.qualifiedTitle
        setAccessibilityLabel(command.qualifiedTitle)
        setAccessibilityValue(catalog.text(enabled ? "Available" : "Unavailable"))
    }
}
