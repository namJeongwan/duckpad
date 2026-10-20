import AppKit
import DuckpadDomain

@MainActor
final class SearchResultLineCell: NSTableCellView {
    private let location = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSTextField(labelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        location.font = .systemFont(ofSize: 12)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        location.alignment = .right
        textField = text
        for field in [text, location] {
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.wraps = false
            field.lineBreakMode = field === text ? .byTruncatingTail : .byTruncatingMiddle
            field.wantsLayer = true
            field.layer?.masksToBounds = true
            field.heightAnchor.constraint(equalToConstant: 18).isActive = true
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: location.leadingAnchor, constant: -18),
            location.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), location.centerYAnchor.constraint(equalTo: centerYAnchor),
            location.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.35),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func apply(title: String, detail: String, query: SearchQuery) {
        // Snippets are display-only; keep embedded separators out of the row layout.
        let displayTitle = String(title.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: displayTitle, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        if query.options.mode == .normal, !query.pattern.isEmpty {
            let source = displayTitle as NSString
            var position = 0
            while position < source.length {
                let range = source.range(of: query.pattern, options: query.options.matchCase ? [] : .caseInsensitive,
                                         range: NSRange(location: position, length: source.length - position))
                guard range.location != NSNotFound, range.length > 0 else { break }
                text.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.6), .foregroundColor: NSColor.black], range: range)
                position = NSMaxRange(range)
            }
        }
        textField?.attributedStringValue = text; location.stringValue = detail
        toolTip = detail + "\n" + title
        setAccessibilityLabel(detail + ", " + title)
    }
}
