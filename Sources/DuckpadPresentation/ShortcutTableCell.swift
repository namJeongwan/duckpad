import AppKit

/// Labels use their intrinsic heights, centered as a group in the table row.
@MainActor
final class ShortcutTableCell: NSTableCellView {
    private var hasError = false
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 11)
        for field in [title, detail] { field.lineBreakMode = .byTruncatingTail }
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        textField = title
        updateColors()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, detail: String?, error: Bool = false, wrapsDetail: Bool = false) {
        hasError = error
        self.detail.maximumNumberOfLines = wrapsDetail ? 3 : 1
        self.detail.cell?.wraps = wrapsDetail
        self.detail.lineBreakMode = wrapsDetail ? .byWordWrapping : .byTruncatingTail
        updateColors()
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail?.isEmpty != false
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    private func updateColors() {
        title.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = hasError ? (backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .systemRed) : (backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}
