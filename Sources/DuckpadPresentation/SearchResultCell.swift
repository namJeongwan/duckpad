import AppKit

/// Dense filename results: file icon, highlighted name, directory and workspace.
@MainActor
final class SearchResultCell: NSTableCellView {
    private let directory = NSTextField(labelWithString: "")
    private let project = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var filename = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "")
        textField = title; imageView = icon
        title.font = .systemFont(ofSize: 13)
        for field in [directory, project] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        for field in [title, directory, project] {
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.wraps = false
            field.lineBreakMode = .byTruncatingMiddle
            field.wantsLayer = true
            field.layer?.masksToBounds = true
            field.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
        directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        project.alignment = .right
        for view in [title, directory, project, icon] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55),
            directory.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8), directory.centerYAnchor.constraint(equalTo: centerYAnchor),
            directory.trailingAnchor.constraint(lessThanOrEqualTo: project.leadingAnchor, constant: -12),
            project.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), project.centerYAnchor.constraint(equalTo: centerYAnchor),
            project.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.2),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshIcon() }
    private func refreshIcon() { icon.image = MaterialFileIconTheme.shared.icon(for: filename, appearance: effectiveAppearance).image }

    func apply(title: String, detail: String, project: String? = nil, query: String = "") {
        filename = title; refreshIcon()
        let displayTitle = String(title.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: displayTitle, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        let source = displayTitle as NSString
        for term in query.split(whereSeparator: \.isWhitespace) {
            var offset = 0
            while offset < source.length {
                let range = source.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: source.length - offset))
                guard range.location != NSNotFound, range.length > 0 else { break }
                text.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.6), .foregroundColor: NSColor.black], range: range)
                offset = NSMaxRange(range)
            }
        }
        textField?.attributedStringValue = text
        directory.stringValue = (detail as NSString).deletingLastPathComponent
        self.project.stringValue = project ?? ""
        toolTip = detail; setAccessibilityLabel(title + ", " + detail)
    }
}
