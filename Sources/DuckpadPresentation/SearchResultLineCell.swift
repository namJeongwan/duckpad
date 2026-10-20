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
        for view in [text, location] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: location.leadingAnchor, constant: -18),
            location.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), location.centerYAnchor.constraint(equalTo: centerYAnchor),
            location.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.35),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func apply(title: String, detail: String, query: SearchQuery) {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
        if query.options.mode == .normal, !query.pattern.isEmpty {
            let source = title as NSString
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
